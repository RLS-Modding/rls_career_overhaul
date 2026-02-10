<template>
  <LayoutSingle class="auction-layout">
    <BngCard class="auction-card">
      <BngCardHeading>Used Car Auction</BngCardHeading>

      <div class="status">{{ state.statusMessage }}</div>

      <div v-if="state.phase === 'travelPrompt'" class="actions">
        <BngButton :accent="ACCENTS.primary" @click="travel">Travel To Auction</BngButton>
        <BngButton :accent="ACCENTS.secondary" @click="cancel">Cancel</BngButton>
      </div>

      <div v-else-if="state.phase === 'bidding'" class="bidding">
        <div class="lot-meta">Lot {{ activeLot?.lotIndex || '-' }} / {{ state.lots.length }}</div>
        <div class="lot-title">{{ activeLot?.title || 'Loading...' }}</div>
        <div class="lot-row">Current Bid: ${{ activeLot?.currentBid || 0 }}</div>
        <div class="lot-row">Highest Bidder: {{ formatBidder(activeLot?.highestBidder) }}</div>
        <div class="lot-row">Time Left: {{ activeLot?.timeLeft || 0 }}s</div>
        <div class="lot-row">Your Wins: {{ state.purchasedCount }}</div>

        <div class="lot-row auto-wrap">
          <label class="auto-label">
            <input type="checkbox" v-model="autoBidEnabled" @change="updateAutoBidEnabled" />
            Auto Bid
          </label>
          <label class="auto-label">
            Max:
            <input class="max-input" type="number" min="0" step="100" v-model.number="autoBidMax" @change="updateAutoBidMax" />
          </label>
        </div>

        <div class="actions">
          <BngButton :accent="ACCENTS.primary" @click="bid(250)">Bid +$250</BngButton>
          <BngButton :accent="ACCENTS.primary" @click="bid(500)">Bid +$500</BngButton>
          <BngButton :accent="ACCENTS.primary" @click="bid(1000)">Bid +$1000</BngButton>
          <BngButton :accent="ACCENTS.primary" @click="bid(5000)">Bid +$5000</BngButton>
          <BngButton :accent="ACCENTS.secondary" @click="pass">Pass This Car</BngButton>
          <BngButton :accent="ACCENTS.tertiary" @click="closeMenu">Close Menu</BngButton>
        </div>
      </div>

      <div v-else-if="state.phase === 'complete'" class="complete">
        <div>Won Cars: {{ state.purchasedCount }}</div>
        <div>Walk to the exit trigger to return to your original location.</div>
        <div class="actions">
          <BngButton :accent="ACCENTS.tertiary" @click="closeMenu">Close Menu</BngButton>
        </div>
      </div>

      <div v-else class="idle">
        <div>Enter the auction trigger while walking to start.</div>
        <div class="actions">
          <BngButton :accent="ACCENTS.tertiary" @click="closeMenu">Close</BngButton>
        </div>
      </div>
    </BngCard>
  </LayoutSingle>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { lua } from '@/bridge'
import { BngButton, ACCENTS, BngCard, BngCardHeading } from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'

const state = ref({ phase: 'idle', activeLotIndex: 1, statusMessage: '', purchasedCount: 0, lots: [] })
const autoBidEnabled = ref(false)
const autoBidMax = ref(0)
let intervalId = null

const getAuctionApi = () => lua?.career_modules_usedCarAuction

const activeLot = computed(() => {
  if (!state.value?.lots?.length) return null
  return state.value.lots[(state.value.activeLotIndex || 1) - 1] || null
})

const refresh = async () => {
  const api = getAuctionApi()
  if (!api?.requestAuctionState) return
  state.value = await api.requestAuctionState()
  autoBidEnabled.value = !!state.value?.autoBidEnabled
  autoBidMax.value = Number(state.value?.autoBidMax || 0)
}

const travel = async () => {
  const api = getAuctionApi()
  if (!api?.startAuction) return
  await api.startAuction()
  await refresh()
}

const cancel = async () => {
  const api = getAuctionApi()
  if (!api?.cancelTravelPrompt) return
  await api.cancelTravelPrompt()
}

const bid = async amount => {
  const api = getAuctionApi()
  if (!api?.placeBid) return
  await api.placeBid(amount)
  await refresh()
}

const pass = async () => {
  const api = getAuctionApi()
  if (!api?.passCurrentLot) return
  await api.passCurrentLot()
  await refresh()
}

const closeMenu = async () => {
  const api = getAuctionApi()
  if (api?.closeMenu) {
    await api.closeMenu()
    return
  }
  // Fallback when module API is unavailable: just navigate back.
  await lua?.guihooks?.trigger?.('UINavigation', 'back', 1)
}

const updateAutoBidEnabled = async () => {
  const api = getAuctionApi()
  if (!api?.setAutoBidEnabled) return
  await api.setAutoBidEnabled(!!autoBidEnabled.value)
  await refresh()
}

const updateAutoBidMax = async () => {
  const api = getAuctionApi()
  if (!api?.setAutoBidMax) return
  await api.setAutoBidMax(Number(autoBidMax.value || 0))
  await refresh()
}

const formatBidder = bidder => {
  if (bidder === 'player') return 'You'
  if (bidder === 'npc') return 'Other Bidder'
  return '-'
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
.auction-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
}

.auction-card {
  width: min(640px, 90vw);
  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.82);
    color: #fff;
    border-radius: 8px;
  }
}

.status {
  margin-bottom: 12px;
  opacity: 0.95;
}

.lot-meta {
  font-size: 0.9rem;
  opacity: 0.85;
}

.lot-title {
  font-size: 1.2rem;
  font-weight: 600;
  margin: 6px 0 8px;
}

.lot-row {
  margin: 3px 0;
}

.auto-wrap {
  display: flex;
  gap: 12px;
  align-items: center;
  flex-wrap: wrap;
}

.auto-label {
  display: flex;
  gap: 6px;
  align-items: center;
}

.max-input {
  width: 120px;
}

.actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 14px;
}
</style>

