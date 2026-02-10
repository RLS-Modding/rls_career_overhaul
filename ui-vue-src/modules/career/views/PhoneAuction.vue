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
          <div class="row"><strong>Lot:</strong> {{ activeLot?.lotIndex || '-' }} / {{ state.lots?.length || 0 }}</div>
          <div class="row"><strong>Car:</strong> {{ activeLot?.title || '-' }}</div>
          <div class="row"><strong>Bid:</strong> ${{ activeLot?.currentBid || 0 }}</div>
          <div class="row"><strong>Leader:</strong> {{ formatBidder(activeLot?.highestBidder) }}</div>
          <div class="row"><strong>Time Left:</strong> {{ activeLot?.timeLeft || 0 }}s</div>

          <div class="row controls">
            <label class="toggle-label">
              <input type="checkbox" v-model="autoBidEnabled" @change="updateAutoBidEnabled" />
              Auto Bid
            </label>
            <label class="max-label">
              Max:
              <input class="max-input" type="number" min="0" step="100" v-model.number="autoBidMax" @change="updateAutoBidMax" />
            </label>
          </div>

          <div class="actions">
            <button class="btn primary" @click="bid(250)">+$250</button>
            <button class="btn primary" @click="bid(500)">+$500</button>
            <button class="btn primary" @click="bid(1000)">+$1000</button>
            <button class="btn primary" @click="bid(5000)">+$5000</button>
            <button class="btn secondary" @click="pass">Pass</button>
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
const autoBidEnabled = ref(false)
const autoBidMax = ref(0)
let intervalId = null

const getAuctionApi = () => lua?.career_modules_usedCarAuction

const ensureAuctionApi = async () => {
  let api = getAuctionApi()
  if (api?.requestAuctionState) return api

  try {
    if (lua?.extensions?.load) {
      await lua.extensions.load('career_modules_usedCarAuction')
    }
  } catch (e) {
    // Ignore load errors; fallback message is handled by caller.
  }

  api = getAuctionApi()
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
  autoBidEnabled.value = !!state.value?.autoBidEnabled
  autoBidMax.value = Number(state.value?.autoBidMax || 0)
}

const bid = async amount => {
  const api = await ensureAuctionApi()
  if (!api?.placeBid) return
  await api.placeBid(amount)
  await refresh()
}

const pass = async () => {
  const api = await ensureAuctionApi()
  if (!api?.passCurrentLot) return
  await api.passCurrentLot()
  await refresh()
}

const updateAutoBidEnabled = async () => {
  const api = await ensureAuctionApi()
  if (!api?.setAutoBidEnabled) return
  await api.setAutoBidEnabled(!!autoBidEnabled.value)
  await refresh()
}

const updateAutoBidMax = async () => {
  const api = await ensureAuctionApi()
  if (!api?.setAutoBidMax) return
  await api.setAutoBidMax(Number(autoBidMax.value || 0))
  await refresh()
}

const formatBidder = bidder => {
  if (bidder === 'player') return 'You'
  if (bidder === 'npc') return 'NPC'
  return '-'
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

.controls {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  align-items: center;
}

.toggle-label,
.max-label {
  display: flex;
  align-items: center;
  gap: 6px;
}

.max-input {
  width: 96px;
  border: 1px solid #cbd5e1;
  border-radius: 6px;
  padding: 3px 6px;
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
