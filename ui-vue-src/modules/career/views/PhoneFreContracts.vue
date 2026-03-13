<template>
  <PhoneWrapper app-name="FRE Contracts">
    <div class="fre-app">
      <div v-if="loading" class="state-screen">
        <div class="state-card">
          <div class="state-eyebrow">Loading</div>
          <div class="state-title">Pulling fresh contract data</div>
          <div class="state-copy">Checking the latest FRE offers and sponsor updates.</div>
        </div>
      </div>
      <div v-else-if="!careerActive" class="state-screen">
        <div class="state-card">
          <div class="state-eyebrow">Career Required</div>
          <div class="state-title">FRE Contracts is locked</div>
          <div class="state-copy">Start Career mode to browse contracts, sponsors, and progression.</div>
        </div>
      </div>
      <template v-else>
        <div class="toolbar-shell">
          <div v-if="selectedDisciplineInfo" class="discipline-summary">
            <div class="summary-head">
              <div ref="disciplineMenuRef" class="summary-main discipline-dropdown-wrap">
                <div class="summary-title-row">
                  <button class="summary-title-btn" :class="{ active: disciplineMenuOpen }" @click.stop="toggleDisciplineMenu" @mousedown.stop>
                    <span class="summary-title">{{ selectedDisciplineLabel }}</span>
                    <svg class="discipline-dropdown-chevron" :class="{ open: disciplineMenuOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                      <polyline points="6 9 12 15 18 9"/>
                    </svg>
                  </button>
                  <div class="summary-title-level">Level {{ selectedDisciplineInfo.level }}</div>
                </div>
                <div v-if="disciplineMenuOpen" class="discipline-dropdown-panel summary-discipline-panel" @click.stop @mousedown.stop>
                  <button
                    v-for="option in disciplineOptions"
                    :key="option.value"
                    class="discipline-dropdown-item"
                    :class="{ selected: option.value === selectedDiscipline }"
                    @click="selectDiscipline(option.value)"
                  >
                    {{ option.label }}
                  </button>
                </div>
              </div>
            </div>
            <div class="summary-strip">
              <div class="summary-meter-card">
                <div class="summary-meter-top">
                  <span class="summary-meter-label">Contracts</span>
                  <span class="summary-meter-value">{{ selectedDisciplineInfo.contractSlotsUsed }}/{{ selectedDisciplineInfo.contractSlots }}</span>
                </div>
              </div>
              <div class="summary-meter-card">
                <div class="summary-meter-top">
                  <span class="summary-meter-label">Sponsors</span>
                  <span class="summary-meter-value">{{ selectedDisciplineInfo.sponsorSlotsUsed }}/{{ selectedDisciplineInfo.sponsorSlots }}</span>
                </div>
              </div>
            </div>
            <div class="summary-bonus">
              <span class="summary-bonus-label">Sponsor Bonus</span>
              <span class="summary-bonus-value">{{ formatPercent(selectedDisciplineInfo.sponsorBonusMoney) }} Money • {{ formatPercent(selectedDisciplineInfo.sponsorBonusXp) }} XP</span>
            </div>
            <div v-if="summaryUnlockMessages.length" class="summary-notes">
              <div v-for="message in summaryUnlockMessages" :key="message" class="summary-note">{{ message }}</div>
            </div>
          </div>
          <div v-else class="discipline-summary compact">
            <div ref="disciplineMenuRef" class="discipline-dropdown-wrap">
              <div class="summary-title-row compact">
                <button class="summary-title-btn" :class="{ active: disciplineMenuOpen }" @click.stop="toggleDisciplineMenu" @mousedown.stop>
                  <span class="summary-title">{{ selectedDisciplineLabel }}</span>
                  <svg class="discipline-dropdown-chevron" :class="{ open: disciplineMenuOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5">
                    <polyline points="6 9 12 15 18 9"/>
                  </svg>
                </button>
              </div>
              <div v-if="disciplineMenuOpen" class="discipline-dropdown-panel summary-discipline-panel" @click.stop @mousedown.stop>
                <button
                  v-for="option in disciplineOptions"
                  :key="option.value"
                  class="discipline-dropdown-item"
                  :class="{ selected: option.value === selectedDiscipline }"
                  @click="selectDiscipline(option.value)"
                >
                  {{ option.label }}
                </button>
              </div>
            </div>
            <div class="summary-compact-copy">Showing combined contracts and sponsors across every discipline.</div>
          </div>

          <div class="tabs">
            <button :class="{ active: tab === 'contracts' }" @click="tab = 'contracts'">
              <span class="tab-label">Contracts</span>
              <span class="tab-count">{{ contractsTabCount }}</span>
            </button>
            <button :class="{ active: tab === 'sponsors' }" @click="tab = 'sponsors'">
              <span class="tab-label">Sponsors</span>
              <span class="tab-count">{{ sponsorsTabCount }}</span>
            </button>
          </div>
        </div>

        <div class="content">
          <div v-if="errorMessage" class="error">{{ errorMessage }}</div>
          <div v-if="tab === 'contracts'" class="panel">
            <section v-if="sortedActiveContracts.length > 0" class="section-block">
              <div class="section-header">
                <div>
                  <div class="section-kicker">In Progress</div>
                  <div class="section-title">Active Contracts</div>
                </div>
                <div class="section-count">{{ sortedActiveContracts.length }}</div>
              </div>
              <article
                v-for="contract in sortedActiveContracts"
                :key="contract.id"
                class="deal-card"
                :class="{ urgent: contractUrgencyTone(contract) === 'urgent' }"
              >
                <div class="deal-card-top">
                  <div class="deal-card-title">{{ contractTitle(contract) }}</div>
                  <div class="deal-card-side">
                    <div class="deal-chip urgency" :class="contractUrgencyTone(contract)">{{ contractUrgencyLabel(contract) }}</div>
                  </div>
                </div>
                <div class="deal-card-meta">
                  <div class="deal-card-focus" :title="contractRaceLabel(contract)">{{ contractRaceLabel(contract) }}</div>
                  <div class="deal-card-vehicle" :title="contractVehicleLabel(contract)">{{ contractVehicleLabel(contract) }}</div>
                </div>
                <div class="deal-card-main">
                  <div class="reward-block">
                    <div class="reward-label">Reward</div>
                    <div class="reward-value">${{ formatMoney(contract.rewardMoney) }}</div>
                    <div class="reward-sub">{{ contract.rewardXp }} XP</div>
                  </div>
                  <div class="objective-block">
                    <div class="objective-label">Objective</div>
                    <div class="objective-value">{{ objectiveStatusLabel(contract) }}</div>
                    <div class="objective-sub">{{ contractTargetLabel(contract) }}</div>
                  </div>
                </div>
                <div class="deal-card-footer">
                  <button class="action-btn danger" :disabled="actionBusy" @click="abandonContract(contract.id)">Abandon</button>
                </div>
              </article>
            </section>

            <section class="section-block">
              <div class="section-header">
                <div>
                  <div class="section-kicker">New Work</div>
                  <div class="section-title">Available Contracts</div>
                </div>
                <div class="section-count">{{ sortedAvailableContracts.length }}</div>
              </div>
              <div v-if="contractsLockedMessage" class="empty-card">
                <div class="empty-card-title">Contracts Locked</div>
                <div class="empty-card-copy">{{ contractsLockedMessage }}</div>
              </div>
              <div v-else-if="sortedAvailableContracts.length === 0" class="empty-card">
                <div class="empty-card-title">No offers available</div>
                <div class="empty-card-copy">No offers available right now. New offers will appear here automatically.</div>
              </div>
              <article
                v-for="contract in sortedAvailableContracts"
                :key="contract.id"
                class="deal-card offer"
                :class="{ urgent: contractUrgencyTone(contract) === 'urgent' }"
              >
                <div class="deal-card-top">
                  <div class="deal-card-title">{{ contractTitle(contract) }}</div>
                  <div class="deal-card-side">
                    <div class="deal-chip urgency" :class="contractUrgencyTone(contract)">{{ contractUrgencyLabel(contract) }}</div>
                  </div>
                </div>
                <div class="deal-card-meta">
                  <div class="deal-card-focus" :title="contractRaceLabel(contract)">{{ contractRaceLabel(contract) }}</div>
                  <div class="deal-card-vehicle" :title="contractVehicleLabel(contract)">{{ contractVehicleLabel(contract) }}</div>
                </div>
                <div class="deal-card-main">
                  <div class="reward-block">
                    <div class="reward-label">Reward</div>
                    <div class="reward-value">${{ formatMoney(contract.rewardMoney) }}</div>
                    <div class="reward-sub">{{ contract.rewardXp }} XP</div>
                  </div>
                  <div class="objective-block">
                    <div class="objective-label">Objective</div>
                    <div class="objective-value">{{ objectiveStatusLabel(contract) }}</div>
                    <div class="objective-sub">{{ contractTargetLabel(contract) }}</div>
                  </div>
                </div>
                <div class="deal-card-footer">
                  <button class="action-btn primary full-width" :disabled="actionBusy || !canAcceptContract(contract)" @click="acceptContract(contract.id)">
                    {{ canAcceptContract(contract) ? 'Accept' : 'Slots Full' }}
                  </button>
                </div>
              </article>
            </section>
          </div>

          <div v-else class="panel">
            <section class="section-block">
              <div class="section-header">
                <div>
                  <div class="section-kicker">Current Deals</div>
                  <div class="section-title">Active Sponsors</div>
                </div>
                <div class="section-count">{{ sortedActiveSponsors.length }}</div>
              </div>
              <div v-if="sortedActiveSponsors.length === 0" class="empty-card">
                <div class="empty-card-title">No active sponsors</div>
                <div class="empty-card-copy">Sign one to add passive money and XP bonuses.</div>
              </div>
              <article
                v-for="sponsor in sortedActiveSponsors"
                :key="sponsor.id"
                class="deal-card sponsor"
                :class="{ warning: sponsor.warningIssued }"
              >
                <div class="deal-card-top">
                  <div class="deal-card-title-wrap">
                    <div class="deal-card-title">{{ sponsorTitle(sponsor) }}</div>
                    <div class="deal-card-focus">{{ bonusLabel(sponsor) }}</div>
                  </div>
                  <div class="deal-chip status" :class="sponsorStatusTone(sponsor)">{{ sponsorStatusLabel(sponsor) }}</div>
                </div>
                <div class="deal-card-main sponsor-main">
                  <div class="reward-block sponsor-bonus">
                    <div class="reward-label">Sponsor Bonus</div>
                    <div class="reward-value compact">{{ bonusLabel(sponsor) }}</div>
                    <div class="reward-sub">Upkeep {{ formatMinutes(displayRemaining(sponsor.checkMinutesRemaining)) }}</div>
                  </div>
                  <div class="objective-block">
                    <div class="objective-label">Requirement</div>
                    <div class="objective-value compact">{{ sponsorRequirementHeadline(sponsor) }}</div>
                    <div class="objective-sub">{{ sponsor.warningIssued ? 'Warning active' : 'Keep requirement satisfied' }}</div>
                  </div>
                </div>
                <div v-if="sponsor.warningIssued" class="warning-panel">
                  Warning active. Complete an event in {{ formatMinutes(displayRemaining(sponsor.checkMinutesRemaining)) }} to keep the sponsor.
                  <button class="inline-action" :disabled="actionBusy" @click="acknowledgeSponsorWarning(sponsor.id)">Acknowledge Warning</button>
                </div>
                <div class="deal-card-footer">
                  <button class="action-btn danger full-width" :disabled="actionBusy" @click="dropSponsor(sponsor.id)">Drop Sponsor</button>
                </div>
              </article>
            </section>
            <section class="section-block">
              <div class="section-header">
                <div>
                  <div class="section-kicker">Open Offers</div>
                  <div class="section-title">Available Sponsors</div>
                </div>
                <div class="section-count">{{ sortedAvailableSponsors.length }}</div>
              </div>
              <div v-if="sponsorsLockedMessage" class="empty-card">
                <div class="empty-card-title">Sponsors Locked</div>
                <div class="empty-card-copy">{{ sponsorsLockedMessage }}</div>
              </div>
              <div v-else-if="sortedAvailableSponsors.length === 0" class="empty-card">
                <div class="empty-card-title">No sponsor offers</div>
                <div class="empty-card-copy">No sponsor offers available right now.</div>
              </div>
              <article v-for="sponsor in sortedAvailableSponsors" :key="sponsor.id" class="deal-card sponsor offer">
                <div class="deal-card-top">
                  <div class="deal-card-title-wrap">
                    <div class="deal-card-title">{{ sponsorTitle(sponsor) }}</div>
                    <div class="deal-card-focus">{{ bonusLabel(sponsor) }}</div>
                  </div>
                  <div class="deal-chip urgency" :class="sponsorOfferTone(sponsor)">{{ sponsorOfferLabel(sponsor) }}</div>
                </div>
                <div class="deal-card-main sponsor-main">
                  <div class="reward-block sponsor-bonus">
                    <div class="reward-label">Sponsor Bonus</div>
                    <div class="reward-value compact">{{ bonusLabel(sponsor) }}</div>
                    <div class="reward-sub">Offer expires {{ formatMinutes(displayRemaining(sponsor.minutesRemaining)) }}</div>
                  </div>
                  <div class="objective-block">
                    <div class="objective-label">Requirement</div>
                    <div class="objective-value compact">{{ sponsorRequirementHeadline(sponsor) }}</div>
                    <div class="objective-sub">Stay active every upkeep window</div>
                  </div>
                </div>
                <div class="deal-card-footer">
                  <button class="action-btn primary full-width" :disabled="actionBusy || !canSignSponsor(sponsor)" @click="signSponsor(sponsor.id)">
                    {{ canSignSponsor(sponsor) ? 'Sign Sponsor' : 'Slots Full' }}
                  </button>
                </div>
              </article>
            </section>
          </div>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'
import { useEvents } from '@/services/events'

const TIMER_TICK_MS = 1000
const SELECTED_DISCIPLINE_KEY = 'phoneFreContracts:selectedDiscipline'

const events = useEvents()
const loading = ref(true)
const actionBusy = ref(false)
const careerActive = ref(true)
const errorMessage = ref('')
const tab = ref('contracts')
const disciplineMenuOpen = ref(false)
const disciplineMenuRef = ref(null)
const lastSyncMs = ref(Date.now())
const nowMs = ref(Date.now())
const state = ref({ disciplines: [], activeContracts: [], availableContracts: [], activeSponsors: [], availableSponsors: [] })

function loadSavedDiscipline() {
  try {
    return localStorage.getItem(SELECTED_DISCIPLINE_KEY) || 'all'
  } catch (error) {
    return 'all'
  }
}

const selectedDiscipline = ref(loadSavedDiscipline())

let tickTimer = null

const disciplines = computed(() => state.value.disciplines || [])
const disciplineOptions = computed(() => [{ value: 'all', label: 'All Disciplines' }, ...disciplines.value.map(discipline => ({ value: discipline.id, label: discipline.label || discipline.id }))])
const disciplineLookup = computed(() => Object.fromEntries(disciplines.value.map(discipline => [discipline.id, discipline])))
const selectedDisciplineInfo = computed(() => selectedDiscipline.value === 'all' ? null : disciplineLookup.value[selectedDiscipline.value] || null)
const selectedDisciplineLabel = computed(() => selectedDisciplineInfo.value?.label || 'All Disciplines')

function filterByDiscipline(list) {
  return selectedDiscipline.value === 'all' ? (list || []) : (list || []).filter(entry => entry.disciplineId === selectedDiscipline.value)
}

function sortByUrgencyThenReward(a, b) {
  return (displayRemaining(a.minutesRemaining) - displayRemaining(b.minutesRemaining)) || (Number(b.rewardMoney || 0) - Number(a.rewardMoney || 0))
}

function sortByWarningThenUpkeep(a, b) {
  return (Boolean(a.warningIssued) === Boolean(b.warningIssued) ? 0 : a.warningIssued ? -1 : 1) || (displayRemaining(a.checkMinutesRemaining) - displayRemaining(b.checkMinutesRemaining))
}

function sortByMinutesRemaining(a, b) {
  return displayRemaining(a.minutesRemaining) - displayRemaining(b.minutesRemaining)
}

const filteredActiveContracts = computed(() => filterByDiscipline(state.value.activeContracts))
const filteredAvailableContracts = computed(() => filterByDiscipline(state.value.availableContracts))
const filteredActiveSponsors = computed(() => filterByDiscipline(state.value.activeSponsors))
const filteredAvailableSponsors = computed(() => filterByDiscipline(state.value.availableSponsors))
const sortedActiveContracts = computed(() => [...filteredActiveContracts.value].sort(sortByUrgencyThenReward))
const sortedAvailableContracts = computed(() => [...filteredAvailableContracts.value].sort(sortByUrgencyThenReward))
const sortedActiveSponsors = computed(() => [...filteredActiveSponsors.value].sort(sortByWarningThenUpkeep))
const sortedAvailableSponsors = computed(() => [...filteredAvailableSponsors.value].sort(sortByMinutesRemaining))
const contractsTabCount = computed(() => sortedActiveContracts.value.length + sortedAvailableContracts.value.length)
const sponsorsTabCount = computed(() => sortedActiveSponsors.value.length + sortedAvailableSponsors.value.length)
const summaryUnlockMessages = computed(() => {
  if (!selectedDisciplineInfo.value) return []
  const messages = []
  if (!selectedDisciplineInfo.value.contractsUnlocked) messages.push(`Contracts unlock at level ${selectedDisciplineInfo.value.contractUnlockLevel}.`)
  if (!selectedDisciplineInfo.value.sponsorsUnlocked) messages.push(`Sponsors unlock at level ${selectedDisciplineInfo.value.sponsorUnlockLevel}.`)
  return messages
})
const contractsLockedMessage = computed(() => !selectedDisciplineInfo.value || selectedDisciplineInfo.value.contractsUnlocked ? '' : `Contracts unlock at level ${selectedDisciplineInfo.value.contractUnlockLevel}.`)
const sponsorsLockedMessage = computed(() => !selectedDisciplineInfo.value || selectedDisciplineInfo.value.sponsorsUnlocked ? '' : `Sponsors unlock at level ${selectedDisciplineInfo.value.sponsorUnlockLevel}.`)

function normalizeList(value) {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== 'object') return []
  return Object.keys(value).sort((a, b) => Number(a) - Number(b)).map(key => value[key]).filter(Boolean)
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
  if (selectedDiscipline.value !== 'all' && !state.value.disciplines.some(discipline => discipline?.id === selectedDiscipline.value)) {
    selectedDiscipline.value = 'all'
  }
  lastSyncMs.value = Date.now()
}

function displayRemaining(baseMinutes) {
  return Math.max(0, Number(baseMinutes || 0) - Math.max(0, (nowMs.value - lastSyncMs.value) / 60000))
}

function disciplineLabel(disciplineId) {
  return disciplineLookup.value[disciplineId]?.label || disciplineId
}

function tierLabel(tier) {
  return tier ? `${tier.charAt(0).toUpperCase()}${tier.slice(1)}` : 'Unknown'
}

function formatMoney(value) {
  return Math.floor(Number(value || 0)).toLocaleString()
}

function formatTime(seconds) {
  const total = Number(seconds || 0)
  const minutes = Math.floor(total / 60)
  const secs = total - minutes * 60
  if (minutes >= 1) return `${minutes}:${String(Math.floor(secs)).padStart(2, '0')}`
  if (secs >= 10) return secs.toFixed(1)
  return secs.toFixed(2)
}

function formatMinutes(minutes) {
  const totalSeconds = Math.max(0, Math.floor(Number(minutes || 0) * 60))
  if (totalSeconds <= 0) return '0s'
  const totalMinutes = Math.floor(totalSeconds / 60)
  if (totalMinutes >= 60) {
    const hours = Math.floor(totalMinutes / 60)
    const minutesRemainder = totalMinutes % 60
    return minutesRemainder > 0 ? `${hours}h ${minutesRemainder}m` : `${hours}h`
  }
  const wholeMinutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  if (wholeMinutes <= 0) return `${seconds}s`
  return `${wholeMinutes}m ${seconds}s`
}

function formatPercent(value) {
  return `${Math.round(Number(value || 0) * 1000) / 10}%`
}

function toggleDisciplineMenu() {
  disciplineMenuOpen.value = !disciplineMenuOpen.value
}

function selectDiscipline(disciplineId) {
  selectedDiscipline.value = disciplineId
  disciplineMenuOpen.value = false
}

watch(selectedDiscipline, (disciplineId) => {
  try {
    localStorage.setItem(SELECTED_DISCIPLINE_KEY, disciplineId || 'all')
  } catch (error) {
    // Ignore storage failures and keep the in-memory selection.
  }
})

function onDocumentPointerDown(event) {
  if (!disciplineMenuRef.value || disciplineMenuRef.value.contains(event.target)) return
  disciplineMenuOpen.value = false
}

function bonusLabel(sponsor) {
  const amount = `${Math.round(Number(sponsor?.bonusPercent || 0) * 1000) / 10}%`
  const type = sponsor?.bonusType === 'disciplineXP' ? 'XP' : sponsor?.bonusType === 'both' ? 'Money + XP' : 'Money'
  return `${amount} ${type}`
}

function inferRouteTypeFromLabel(label) {
  const text = String(label || '').toLowerCase()
  return text.includes('alt route') || text.includes('alternative route') || text.includes('(alt)') ? 'alt' : 'main'
}

function routeLabel(routeType, fallbackLabel) {
  const normalized = String(routeType || '').toLowerCase() || inferRouteTypeFromLabel(fallbackLabel)
  return normalized === 'alt' ? 'Alt Route' : 'Main Route'
}

function contractRaceLabel(contract) {
  const raceLabel = contract?.raceLabel || contract?.raceName || 'Race'
  const routeType = String(contract?.raceRouteType || '').toLowerCase()
  if (routeType === 'alt') {
    return `${raceLabel} (Alt Route)`
  }
  return raceLabel
}

function contractVehicleLabel(contract) {
  return contract?.requiredModelLabel || contract?.requiredModelFamily || contract?.requiredModel || 'Any model'
}

function contractTitle(contract) {
  return `${disciplineLabel(contract?.disciplineId)} - ${tierLabel(contract?.tier)}`
}

function sponsorTitle(sponsor) {
  return `${disciplineLabel(sponsor?.disciplineId)} - ${sponsor?.name || 'Sponsor'}`
}

function sponsorRequirementHeadline(sponsor) {
  const raceLabel = sponsor?.requiredRaceLabel || sponsor?.requiredRaceName
  const targetLabel = formatTargetLabel(sponsor)
  return raceLabel && targetLabel ? `${targetLabel} on ${raceLabel}` : '1 valid event per upkeep'
}

function sponsorStatusLabel(sponsor) {
  const status = String(sponsor?.requirementStatus || 'pending')
  if (status === 'warning') return 'Warning'
  if (status === 'satisfied') return 'Satisfied'
  return 'Pending'
}

function sponsorStatusTone(sponsor) {
  const status = String(sponsor?.requirementStatus || 'pending')
  if (status === 'warning') return 'warning'
  if (status === 'satisfied') return 'good'
  return 'neutral'
}

function sponsorOfferTone(sponsor) {
  const minutes = displayRemaining(sponsor?.minutesRemaining)
  if (minutes < 1) return 'urgent'
  if (minutes <= 3) return 'soon'
  return 'normal'
}

function sponsorOfferLabel(sponsor) {
  return `${formatMinutes(displayRemaining(sponsor?.minutesRemaining))} left`
}

function normalizeTargetType(targetType) {
  const normalized = String(targetType || '').toLowerCase()
  if (normalized === 'driftscore') return 'driftScore'
  if (normalized === 'maxdamagepct') return 'maxDamagePct'
  return 'time'
}

function formatTargetLabel(entry) {
  const targetType = normalizeTargetType(entry?.targetType)
  if (targetType === 'driftScore') {
    const targetScore = Math.max(0, Math.floor(Number(entry?.targetDriftScore || 0)))
    return targetScore > 0 ? `Score ${targetScore}` : ''
  }
  if (targetType === 'maxDamagePct') {
    const targetDamage = Number(entry?.targetDamagePctMax)
    if (!Number.isFinite(targetDamage)) return ''
    const pct = Math.max(0, Math.min(100, Math.round(targetDamage * 100)))
    return `Max ${pct}% damage`
  }
  const target = Number(entry?.targetTime)
  return Number.isFinite(target) && target > 0 ? `Target ${formatTime(target)}` : ''
}

function contractTargetLabel(contract) {
  return formatTargetLabel(contract)
}

function objectiveStatusLabel(contract) {
  const requiredCount = Math.max(1, Math.floor(Number(contract?.requiredCount || 1)))
  if (contract?.objectiveType === 'laps') return `${requiredCount} lap${requiredCount === 1 ? '' : 's'}`
  return `${Math.max(0, Math.floor(Number(contract?.progress || 0)))}/${requiredCount} events`
}

function contractUrgencyTone(contract) {
  const minutes = displayRemaining(contract?.minutesRemaining)
  if (minutes < 1) return 'urgent'
  if (minutes <= 3) return 'soon'
  return 'normal'
}

function contractUrgencyLabel(contract) {
  return `${formatMinutes(displayRemaining(contract?.minutesRemaining))} left`
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

function handleFreContractsData(data) {
  applyState(data)
  errorMessage.value = ''
  loading.value = false
}

async function performAction(action, id) {
  if (actionBusy.value) return
  actionBusy.value = true
  try {
    const result = await action(id)
    errorMessage.value = result?.ok === false ? (result.error || 'Action failed.') : ''
  } catch (error) {
    errorMessage.value = 'Action failed.'
    await refreshState()
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
  document.addEventListener('pointerdown', onDocumentPointerDown)
  events.on('phoneFreContractsData', handleFreContractsData)
  try {
    await lua.extensions.load('ui_phone_freContracts')
    await lua.ui_phone_freContracts.startLiveUpdates()
  } catch (error) {
    errorMessage.value = 'Unable to load FRE contract services.'
    loading.value = false
    return
  }
  await refreshState()
  tickTimer = setInterval(() => {
    nowMs.value = Date.now()
  }, TIMER_TICK_MS)
})

onUnmounted(async () => {
  document.removeEventListener('pointerdown', onDocumentPointerDown)
  events.off('phoneFreContractsData', handleFreContractsData)
  try {
    await lua.ui_phone_freContracts?.stopLiveUpdates?.()
  } catch (error) {
    // Ignore unload-time errors and let the app close cleanly.
  }
  if (tickTimer) clearInterval(tickTimer)
  tickTimer = null
})
</script>

<style scoped lang="scss">
.fre-app{height:100%;overflow-y:auto;color:#f4f0ea;background:#12161d;padding:46px 10px 18px;scrollbar-width:thin;scrollbar-color:rgba(255,255,255,.18) transparent}
.fre-app::-webkit-scrollbar{width:4px}.fre-app::-webkit-scrollbar-track{background:transparent}.fre-app::-webkit-scrollbar-thumb{background:rgba(255,255,255,.16);border-radius:999px}
.state-screen{min-height:100%;display:flex;align-items:center;justify-content:center;padding:8px 0 24px}
.state-card,.empty-card,.deal-card{border-radius:18px;border:1px solid rgba(255,255,255,.08);background:#171c25;box-shadow:0 14px 34px rgba(0,0,0,.22)}
.state-card{width:100%;padding:18px 16px}.state-eyebrow,.section-kicker,.summary-kicker,.reward-label,.objective-label,.detail-label{font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}.state-eyebrow,.section-kicker,.summary-kicker{color:rgba(244,193,156,.82)}.state-title{margin-top:6px;font-size:18px;font-weight:700;line-height:1.15}.state-copy,.empty-card-copy,.detail-copy{margin-top:8px;color:rgba(228,233,242,.72);font-size:13px;line-height:1.35}
.toolbar-shell,.panel,.section-block{display:flex;flex-direction:column}.toolbar-shell{gap:8px}.panel{gap:16px}.section-block{gap:9px}.deal-card-footer,.summary-title-row,.summary-bonus,.section-header,.tabs,.deal-card-top,.deal-card-meta,.summary-meter-top{display:flex}
.summary-bonus,.section-header,.deal-card-top,.summary-meter-top{justify-content:space-between}.summary-bonus,.section-header,.deal-card-top{gap:10px}.section-header{align-items:end;padding:0 2px}
.discipline-dropdown-wrap{position:relative;min-width:0}.discipline-dropdown-chevron{flex:0 0 auto;transition:transform .15s ease}.discipline-dropdown-chevron.open{transform:rotate(180deg)}.discipline-dropdown-panel{position:absolute;top:100%;left:0;right:0;margin-top:6px;z-index:110;padding:8px;border-radius:14px;border:1px solid rgba(255,255,255,.1);background:#171c25;box-shadow:0 12px 28px rgba(0,0,0,.3)}.summary-discipline-panel{left:0;right:auto;min-width:220px;max-width:min(280px,100%)}.discipline-dropdown-item{display:block;width:100%;padding:10px 12px;border:none;border-radius:10px;background:transparent;color:rgba(228,233,242,.82);font:inherit;font-size:12px;font-weight:600;text-align:left;cursor:pointer}.discipline-dropdown-item.selected{background:rgba(224,107,50,.18);color:#fff7f1}.discipline-dropdown-item:not(.selected):hover{background:rgba(255,255,255,.05)}
.action-btn,.inline-action,.tabs button{transition:transform .16s ease,background-color .16s ease,border-color .16s ease,color .16s ease,opacity .16s ease}.action-btn:active,.inline-action:active,.tabs button:active{transform:scale(.985)}
.action-btn:disabled,.inline-action:disabled{opacity:.48}
.discipline-summary{padding:14px;border-radius:18px;border:1px solid rgba(255,255,255,.08);background:#1a2029;box-shadow:0 16px 40px rgba(0,0,0,.24)}.discipline-summary.compact{display:flex;flex-direction:column;gap:8px;padding:12px 14px}.summary-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:12px}.summary-main{flex:1;min-width:0}.summary-title-row{display:flex;align-items:baseline;justify-content:space-between;gap:10px;width:100%}.summary-title-row.compact{justify-content:flex-start}.summary-title-btn{display:inline-flex;align-items:center;gap:8px;min-width:0;padding:0;border:none;background:transparent;color:#f6f3ee;font:inherit;font-weight:700;cursor:pointer;text-align:left}.summary-title-btn.active .summary-title,.summary-title-btn:hover .summary-title{color:#fff7f1}.summary-title{font-size:17px;font-weight:700;line-height:1.1;min-width:0}.summary-title-level{color:rgba(220,227,236,.78);font-size:13px;font-weight:700;flex:0 0 auto;text-align:right}.summary-compact-copy{color:rgba(228,233,242,.7);font-size:12px;line-height:1.35}.summary-note,.summary-meter-label,.summary-bonus-label{color:rgba(220,227,236,.62);font-size:11px}.summary-meter-value{color:#f6f3ee;font-size:12px;font-weight:700}
.summary-strip,.detail-grid,.deal-card-main{display:grid}.summary-strip,.detail-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.summary-meter-card,.reward-block,.objective-block,.detail-card{padding:12px;border-radius:14px;border:1px solid rgba(255,255,255,.06);background:rgba(255,255,255,.03);min-width:0}.summary-meter-top{align-items:baseline}.summary-strip{margin-top:2px}.summary-bonus{margin-top:16px;padding-top:12px;border-top:1px solid rgba(255,255,255,.06);font-size:12px}.summary-notes{display:flex;flex-direction:column;gap:5px;margin-top:10px}
.tabs{gap:6px;padding:3px;border-radius:16px;border:1px solid rgba(255,255,255,.06);background:rgba(13,16,22,.62)}.tabs button{flex:1;display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 12px;border:none;border-radius:12px;background:transparent;color:rgba(214,222,235,.72);font-weight:700}.tabs button.active{background:linear-gradient(180deg,rgba(224,107,50,.92),rgba(180,76,28,.92));color:#fff7f1;box-shadow:0 8px 18px rgba(180,76,28,.26)}.tab-label{font-size:13px}.tab-count,.section-count{padding:3px 8px;border-radius:999px;background:rgba(255,255,255,.08);font-size:11px;line-height:1}.tabs button.active .tab-count{background:rgba(255,255,255,.16)}.content{margin-top:12px}
.section-title{margin-top:4px;font-size:18px;font-weight:700;line-height:1.1}.section-count{min-width:32px;padding:6px 9px;color:rgba(245,240,234,.9);font-weight:700;text-align:center}.empty-card{padding:16px 15px}.empty-card-title,.deal-card-title{font-size:15px;font-weight:700}.deal-card{padding:14px}.deal-card.offer{border-color:rgba(228,114,56,.12)}.deal-card.urgent{border-color:rgba(249,186,88,.28)}.deal-card.warning{border-color:rgba(240,186,69,.26)}
.deal-card-top{align-items:flex-start}.deal-card-side{display:flex;justify-content:flex-end;flex:0 0 auto;min-width:0}.deal-card-meta{align-items:baseline;justify-content:space-between;gap:12px;margin-top:6px}.deal-card-focus{flex:1;min-width:0;color:rgba(219,226,237,.66);font-size:12px;font-weight:500;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.deal-card-vehicle{flex:0 0 auto;max-width:38%;color:rgba(219,226,237,.72);font-size:12px;font-weight:600;line-height:1.2;text-align:right;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.deal-chip{flex-shrink:0;max-width:112px;padding:6px 9px;border-radius:999px;font-size:10px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;text-align:center;line-height:1.15}.deal-chip.urgency.normal,.deal-chip.status.neutral{border:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.04);color:rgba(234,239,245,.72)}.deal-chip.urgency.soon{border:1px solid rgba(255,178,104,.28);background:rgba(217,112,53,.16);color:#ffd7b6}.deal-chip.urgency.urgent,.deal-chip.status.warning{border:1px solid rgba(250,206,107,.32);background:rgba(249,187,70,.18);color:#ffe39f}.deal-chip.status.good{border:1px solid rgba(90,194,129,.26);background:rgba(64,155,95,.16);color:#b5ebc5}
.deal-card-main{grid-template-columns:1.15fr .9fr;gap:8px;margin-top:12px}.deal-card-main.sponsor-main{grid-template-columns:1fr 1fr}.reward-label,.objective-label,.detail-label{color:rgba(219,226,237,.6)}.reward-value,.objective-value,.detail-value{margin-top:6px;font-weight:700;line-height:1.15;word-break:break-word}.reward-value{font-size:23px}.reward-value.compact,.objective-value.compact{font-size:16px}.objective-value{font-size:17px}.detail-value{font-size:13px}.reward-sub,.objective-sub{margin-top:6px;color:rgba(219,226,237,.62);font-size:11px}.deal-card-footer{gap:8px;margin-top:12px}
.action-btn{min-height:42px;border-radius:13px;font-size:12px;font-weight:700;flex:1;border:1px solid rgba(255,255,255,.08);color:#fff9f5}.action-btn.primary{background:linear-gradient(180deg,#e06d32,#ba4e1d);box-shadow:0 10px 24px rgba(186,78,29,.22)}.action-btn.danger{background:linear-gradient(180deg,rgba(131,63,53,.92),rgba(96,40,35,.92))}.action-btn.full-width{width:100%;flex:1 1 100%}
.warning-panel{margin-top:10px;padding:11px 12px;border-radius:14px;border:1px solid rgba(250,206,107,.22);background:rgba(249,187,70,.11);color:#ffe5ad;font-size:11px;line-height:1.45}.inline-action{margin-top:9px;padding:9px 12px;border-radius:12px;border:1px solid rgba(250,206,107,.24);background:rgba(255,238,195,.06);color:#ffeabf;font-size:11px;font-weight:700}.error{margin-bottom:12px;padding:10px 12px;border-radius:14px;border:1px solid rgba(208,84,84,.34);background:rgba(140,42,42,.22);color:#ffbfbf;font-size:12px}
</style>
