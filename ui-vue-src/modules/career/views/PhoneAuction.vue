<template>
  <PhoneWrapper app-name="Auction" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="phone-auction">
      <div class="section">
        <div class="section-title">Live Auction</div>
        <div class="section-card">
          <div class="status">{{ state.statusMessage }}</div>
          <div class="row"><strong>Phase:</strong> {{ state.phase || 'idle' }}</div>
          <div class="row"><strong>Your Wins:</strong> {{ state.purchasedCount || 0 }}</div>
        </div>
      </div>

      <div class="section" v-if="hasAuctionLot">
        <div class="section-title">Current Lot</div>
        <div class="section-card">
          <div class="tabs">
            <button
              v-for="lot in (state.lots || [])"
              :key="lot.lotIndex"
              class="tab-btn"
              :class="{ selected: Number(selectedLotIndex) === Number(lot.lotIndex), live: Number(currentLotIndex) === Number(lot.lotIndex) }"
              @click="selectLot(lot.lotIndex)">
              Lot {{ lot.lotIndex }}
            </button>
          </div>

          <div class="row"><strong>Selected:</strong> Lot {{ selectedLot?.lotIndex || '-' }} / {{ state.lots?.length || 0 }}</div>
          <div class="row"><strong>Car:</strong> {{ selectedLot?.title || '-' }}</div>
          <div class="row"><strong>Mileage:</strong> {{ formatMileage(selectedLot?.mileage) }}</div>
          <div class="row"><strong>State:</strong> {{ selectedLot?.state || '-' }}</div>
          <div class="row"><strong>Bid:</strong> ${{ selectedLot?.currentBid || 0 }}</div>
          <div class="row"><strong>Leader:</strong> {{ formatBidder(selectedLot) }}</div>
          <div class="row"><strong>Time Left:</strong> {{ selectedLot?.timeLeft || 0 }}s</div>

          <div class="actions">
            <button class="btn primary" @click="bid(250)">+$250</button>
            <button class="btn primary" @click="bid(500)">+$500</button>
            <button class="btn primary" @click="bid(1000)">+$1000</button>
            <button class="btn primary" @click="bid(5000)">+$5000</button>
          </div>
        </div>
      </div>

      <div class="section" v-else>
        <div class="section-title">Info</div>
        <div class="section-card">
          <div class="row">{{ idleMessage }}</div>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'

const state = ref({ phase: 'idle', activeLotIndex: 1, currentLotIndex: null, hasLiveLot: false, currentLot: null, statusMessage: '', purchasedCount: 0, lots: [] })
const selectedLotIndex = ref(null)
let intervalId = null

const getAuctionApi = () => lua?.career_modules_usedCarAuction

const ensureAuctionApi = async () => {
  const api = getAuctionApi()
  if (api?.requestAuctionState) return api
  return null
}

const isAuctionLotState = lotState => {
  return lotState === 'queued' || lotState === 'approaching' || lotState === 'active' || lotState === 'exiting'
}

const activeLot = computed(() => {
  if (state.value?.currentLot) return state.value.currentLot
  if (!state.value?.lots?.length) return null
  const currentLotIndex = Number(state.value.currentLotIndex || 0)
  if (currentLotIndex > 0) {
    const direct = state.value.lots.find(lot => Number(lot?.lotIndex || 0) === currentLotIndex)
    if (direct) return direct
  }
  const indexed = state.value.lots[(state.value.activeLotIndex || 1) - 1]
  if (indexed) return indexed
  return state.value.lots.find(lot => isAuctionLotState(lot?.state)) || null
})

const currentLotIndex = computed(() => {
  const idx = Number(state.value?.currentLotIndex || state.value?.activeLotIndex || 0)
  return idx > 0 ? idx : null
})

const selectedLot = computed(() => {
  const lots = state.value?.lots || []
  if (!lots.length) return null
  const selected = Number(selectedLotIndex.value || 0)
  if (selected > 0) {
    const localMatch = lots.find(lot => Number(lot?.lotIndex || 0) === selected)
    if (localMatch) return localMatch
  }
  return activeLot.value || lots[0]
})

const hasAuctionLot = computed(() => {
  if (state.value?.hasLiveLot) return true
  if (activeLot.value) return true
  const phase = state.value?.phase
  if (phase === 'bidding' || phase === 'starting') return true
  return !!state.value?.lots?.some(lot => isAuctionLotState(lot?.state))
})

const idleMessage = computed(() => {
  if (state.value?.statusMessage) return state.value.statusMessage
  return 'No active in-person lot right now.'
})

const refresh = async () => {
  const api = await ensureAuctionApi()
  if (!api?.requestAuctionState) {
    state.value = {
      phase: 'idle',
      activeLotIndex: 1,
      currentLotIndex: null,
      hasLiveLot: false,
      currentLot: null,
      statusMessage: 'Auction service unavailable right now.',
      purchasedCount: 0,
      lots: []
    }
    return
  }
  const nextState = await api.requestAuctionState()
  if (!nextState || typeof nextState !== 'object') return
  state.value = nextState

  if (!selectedLotIndex.value && Number(state.value?.currentLotIndex || 0) > 0) {
    selectedLotIndex.value = Number(state.value.currentLotIndex)
  }
}

const bid = async amount => {
  const api = await ensureAuctionApi()
  if (!api?.placeBid) return
  await api.placeBid(amount)
  await refresh()
}

const selectLot = lotIndex => {
  selectedLotIndex.value = Number(lotIndex || 1)
}

const formatBidder = lot => {
  if (!lot) return '-'
  const bidderName = `${lot?.highestBidderName || ''}`.trim()
  if (bidderName) return bidderName
  if (lot?.highestBidder === 'player') return 'You'
  if (lot?.highestBidder === 'npc') return 'NPC'
  return '-'
}

const formatMileage = mileage => {
  const n = Number(mileage)
  if (!Number.isFinite(n) || n <= 0) return 'Unknown'
  return `${n.toLocaleString()} mi`
}

onMounted(async () => {
  await refresh()
  intervalId = setInterval(refresh, 500)
})

onUnmounted(() => {
  if (intervalId) clearInterval(intervalId)
  intervalId = null
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background: linear-gradient(180deg, #f7f9ff 0%, #e9f0ff 100%);
}

.phone-auction {
  padding: 10px;
  padding-top: 60px;
  height: 95%;
  overflow-y: auto;
  color: #0f172a;
}

.section {
  margin-bottom: 10px;
}

.section-title {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: .04em;
  text-transform: uppercase;
  color: #334155;
  margin-bottom: 6px;
}

.section-card {
  background: #fff;
  border: 1px solid #dbe5ff;
  border-radius: 12px;
  padding: 10px;
}

.status {
  font-size: 13px;
  color: #1e293b;
  margin-bottom: 6px;
}

.row {
  font-size: 13px;
  margin: 4px 0;
}

.tabs {
  display: flex;
  gap: 6px;
  margin-bottom: 8px;
  flex-wrap: wrap;
}

.tab-btn {
  border: 1px solid #cbd5e1;
  background: #f8fafc;
  border-radius: 999px;
  padding: 4px 10px;
  font-size: 12px;
  font-weight: 700;
  color: #334155;
}

.tab-btn.selected {
  background: #1d4ed8;
  border-color: #1d4ed8;
  color: #fff;
}

.tab-btn.live {
  box-shadow: 0 0 0 2px rgba(249, 115, 22, 0.35);
}

.actions {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 6px;
  margin-top: 8px;
}

.btn {
  border: none;
  border-radius: 8px;
  padding: 8px;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
}

.btn.primary {
  background: #2563eb;
  color: #fff;
}

.btn.secondary {
  background: #64748b;
  color: #fff;
}
</style>
