<template>
  <div class="auction-overlay-layout">
    <template v-if="isEntryPrompt">
      <div class="entry-modal-backdrop">
        <div class="entry-modal">
          <div class="entry-modal-text">{{ entryPromptMessage }}</div>
          <div v-if="!state.canPayEntryFee" class="entry-note">Insufficient funds.</div>
          <div class="entry-modal-actions">
            <BngButton :accent="ACCENTS.primary" :disabled="!state.canPayEntryFee" @click="startAuctionFromPrompt">
              Pay
            </BngButton>
            <BngButton :accent="ACCENTS.secondary" @click="cancelEntryPrompt">
              Cancel
            </BngButton>
          </div>
        </div>
      </div>
    </template>
    <div v-else class="auction-overlay">
      <div class="overlay-header">
        <div class="title">Used Car Auction</div>
        <div class="phase">{{ state.phase || 'idle' }}</div>
      </div>

      <div class="status">{{ state.statusMessage || 'Auction service unavailable.' }}</div>

      <div class="music-toggle">
        <BngSwitch v-model="musicEnabled">Synthwave Music</BngSwitch>
      </div>

      <div class="summary">
        <div class="summary-row">
          <span class="k">Wins</span>
          <span class="v">{{ state.purchasedCount || 0 }}</span>
        </div>
        <div class="summary-row">
          <span class="k">Live Lot</span>
          <span class="v">Lot {{ activeLot?.lotIndex || '-' }}</span>
        </div>
      </div>

      <div class="lots-table">
        <div class="table-row table-head">
          <div class="col-lot">Lot</div>
          <div class="col-vehicle">Vehicle</div>
          <div class="col-mileage">Mileage</div>
        </div>

        <div
          v-for="lot in (state.lots || [])"
          :key="lot.lotIndex"
          class="table-row lot-row"
          :class="{ active: isActiveLot(lot) }"
        >
          <div class="col-lot">Lot {{ lot.lotIndex }}</div>
          <div class="col-vehicle" :title="lot.title || '-'">{{ lot.title || '-' }}</div>
          <div class="col-mileage">{{ formatMileage(lot.mileage) }}</div>
        </div>

        <div v-if="!(state.lots || []).length" class="empty-lots">
          No active lots.
        </div>
      </div>

      <div class="active-details" v-if="activeLot">
        <div class="detail-row">
          <span class="k">Bid</span>
          <span class="v">${{ activeLot.currentBid || 0 }}</span>
        </div>
        <div class="detail-row">
          <span class="k">Leader</span>
          <span class="v">{{ formatBidder(activeLot) }}</span>
        </div>
        <div class="detail-row">
          <span class="k">Time Left</span>
          <span class="v">{{ activeLot.timeLeft || 0 }}s</span>
        </div>
      </div>

      <div class="actions" v-if="canBid">
        <BngButton :accent="ACCENTS.primary" @click="bid(250)">+$250</BngButton>
        <BngButton :accent="ACCENTS.primary" @click="bid(500)">+$500</BngButton>
        <BngButton :accent="ACCENTS.primary" @click="bid(1000)">+$1000</BngButton>
        <BngButton :accent="ACCENTS.primary" @click="bid(5000)">+$5000</BngButton>
      </div>
      <div v-if="state.bidMessage" class="bid-hint">{{ state.bidMessage }}</div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { lua } from '@/bridge'
import { BngButton, ACCENTS, BngSwitch } from '@/common/components/base'

const defaultState = () => ({
  phase: 'idle',
  musicEnabled: true,
  entryPromptActive: false,
  entryFee: 1000,
  canPayEntryFee: false,
  activeLotIndex: 1,
  currentLotIndex: null,
  statusMessage: '',
  purchasedCount: 0,
  bidMessage: '',
  lots: [],
})

const state = ref(defaultState())

let intervalId = null

const getAuctionApi = () => lua?.career_modules_usedCarAuction

const isAuctionLotState = lotState => {
  return lotState === 'queued' || lotState === 'approaching' || lotState === 'active' || lotState === 'exiting'
}

const isEntryPrompt = computed(() => {
  return state.value?.phase === 'entryPrompt' || state.value?.entryPromptActive === true
})

const entryFee = computed(() => {
  const fee = Number(state.value?.entryFee)
  return Number.isFinite(fee) && fee >= 0 ? fee : 1000
})

const entryPromptMessage = computed(() => {
  return `Do you want to pay $${Math.round(entryFee.value)} to enter The Vault?`
})

const activeLot = computed(() => {
  const lots = state.value?.lots || []
  if (!lots.length) return null

  const currentLotIndex = Number(state.value.currentLotIndex || state.value.activeLotIndex || 0)
  if (currentLotIndex > 0) {
    const direct = lots.find(lot => Number(lot?.lotIndex || 0) === currentLotIndex)
    if (direct) return direct
  }

  const activeByState = lots.find(lot => isAuctionLotState(lot?.state))
  if (activeByState) return activeByState
  return lots[0]
})

const canBid = computed(() => {
  const lot = activeLot.value
  if (!lot || lot.state !== 'active' || state.value?.phase !== 'bidding') return false
  if (lot.highestBidder === 'player') return false
  return true
})

const musicEnabled = computed({
  get: () => state.value?.musicEnabled !== false,
  set: enabled => {
    void setAuctionMusicEnabled(enabled)
  }
})

const refresh = async () => {
  const api = getAuctionApi()
  if (!api?.requestAuctionState) {
    state.value = { ...defaultState(), statusMessage: 'Auction service unavailable right now.' }
    return
  }

  const nextState = await api.requestAuctionState()
  if (!nextState || typeof nextState !== 'object') return
  state.value = nextState
}

const setAuctionMusicEnabled = async enabled => {
  const boolEnabled = enabled === true
  state.value = { ...state.value, musicEnabled: boolEnabled }

  const api = getAuctionApi()
  if (!api?.setAuctionMusicEnabled) return
  await api.setAuctionMusicEnabled(boolEnabled)
}

const bid = async amount => {
  const api = getAuctionApi()
  if (!api?.placeBid) return
  await api.placeBid(amount)
  await refresh()
}

const startAuctionFromPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.startAuction) return
  await api.startAuction()
  await refresh()
}

const cancelEntryPrompt = async () => {
  const api = getAuctionApi()
  if (!api?.cancelTravelPrompt) return
  await api.cancelTravelPrompt()
}

const isActiveLot = lot => {
  if (!lot || !activeLot.value) return false
  return Number(lot.lotIndex) === Number(activeLot.value.lotIndex)
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

const formatCurrency = amount => {
  const n = Number(amount)
  if (!Number.isFinite(n) || n < 0) return '$0'
  return `$${n.toLocaleString()}`
}

onMounted(async () => {
  await refresh()
  intervalId = setInterval(refresh, 500)
})

onUnmounted(() => {
  if (intervalId) {
    clearInterval(intervalId)
    intervalId = null
  }
})
</script>

<style scoped lang="scss">
.auction-overlay-layout {
  position: fixed;
  inset: 0;
  pointer-events: none;
}

.entry-modal-backdrop {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.35);
  pointer-events: auto;
}

.entry-modal {
  width: min(34rem, calc(100vw - 2rem));
  border-radius: 0.6rem;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(8, 10, 14, 0.95);
  color: #f5f7fa;
  box-shadow: 0 0.8rem 1.8rem rgba(0, 0, 0, 0.45);
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
}

.entry-modal-text {
  font-size: 0.95rem;
  font-weight: 700;
}

.entry-modal-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.4rem;
}

.auction-overlay {
  position: fixed;
  top: 1.2rem;
  left: 1.2rem;
  width: min(30rem, calc(100vw - 2rem));
  max-height: calc(100vh - 2.4rem);
  overflow: hidden;
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  padding: 0.8rem;
  border-radius: 0.55rem;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(8, 10, 14, 0.88);
  color: #f5f7fa;
  box-shadow: 0 0.8rem 1.8rem rgba(0, 0, 0, 0.45);
  pointer-events: auto;
}

.overlay-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.7rem;
}

.title {
  font-size: 0.92rem;
  font-weight: 800;
  letter-spacing: 0.03rem;
  text-transform: uppercase;
}

.phase {
  font-size: 0.72rem;
  font-weight: 700;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.72);
}

.status {
  font-size: 0.82rem;
  color: rgba(255, 255, 255, 0.88);
}

.music-toggle {
  display: flex;
  align-items: center;
  justify-content: flex-start;
}

.entry-note {
  font-size: 0.76rem;
  color: rgba(255, 182, 182, 0.95);
}

.summary {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.35rem;
}

.summary-row,
.detail-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6rem;
  border-radius: 0.38rem;
  padding: 0.32rem 0.46rem;
  background: rgba(255, 255, 255, 0.05);
}

.k {
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.02rem;
  color: rgba(255, 255, 255, 0.68);
}

.v {
  font-size: 0.8rem;
  font-weight: 700;
  text-align: right;
}

.lots-table {
  display: flex;
  flex-direction: column;
  gap: 0.16rem;
  max-height: 11.5rem;
  overflow-y: auto;
  padding-right: 0.1rem;
}

.table-row {
  display: grid;
  grid-template-columns: 4.6rem 1fr 5.6rem;
  align-items: center;
  gap: 0.55rem;
}

.table-head {
  padding: 0.1rem 0.4rem 0.2rem;
}

.table-head .col-lot,
.table-head .col-vehicle,
.table-head .col-mileage {
  font-size: 0.72rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02rem;
  color: rgba(255, 255, 255, 0.76);
}

.lot-row {
  border-radius: 0.42rem;
  padding: 0.36rem 0.4rem;
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.lot-row.active {
  border-color: rgba(249, 115, 22, 0.82);
  background: rgba(249, 115, 22, 0.14);
}

.col-lot,
.col-vehicle,
.col-mileage {
  font-size: 0.82rem;
}

.col-lot {
  color: rgba(255, 255, 255, 0.9);
}

.col-vehicle {
  font-weight: 700;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.col-mileage {
  font-size: 0.76rem;
  text-align: right;
  color: rgba(255, 255, 255, 0.88);
  white-space: nowrap;
}

.empty-lots {
  font-size: 0.78rem;
  color: rgba(255, 255, 255, 0.66);
  padding: 0.22rem 0.08rem;
}

.active-details {
  display: flex;
  flex-direction: column;
  gap: 0.34rem;
}

.actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.36rem;
}

.actions :deep(.bng-button) {
  min-height: 1.85rem;
  font-size: 0.76rem;
  font-weight: 800;
}

.bid-hint {
  font-size: 0.78rem;
  color: rgba(255, 185, 120, 0.95);
  margin-top: 0.2rem;
}
</style>
