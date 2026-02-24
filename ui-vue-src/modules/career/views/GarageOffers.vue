<template>
  <ComputerWrapper title="Property Offers" back @back="goBack">
    <div class="offers-panel">
        <!-- Property Header -->
        <div class="property-header" v-if="property">
          <div class="header-preview">
            <img v-if="property.preview" :src="property.preview" alt="" class="header-img" />
            <div class="header-fade"></div>
            <div class="header-badges">
              <span class="tag listed">LISTED</span>
            </div>
          </div>
          <div class="header-body">
            <h1 class="header-name">{{ property.name }}</h1>
            <div class="header-prices">
              <div class="price-item">
                <span class="price-label">Your Asking Price</span>
                <span class="price-value">${{ formatPrice(property.askingPrice) }}</span>
              </div>
              <div class="price-divider"></div>
              <div class="price-item">
                <span class="price-label">Market Value</span>
                <span class="price-value dim">${{ formatPrice(property.marketValue) }}</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Loading -->
        <div v-if="loading" class="loading-state">
          Loading offers...
        </div>

        <!-- No Offers -->
        <div v-else-if="!offers || offers.length === 0" class="empty-offers">
          <div class="empty-card">
            <div class="empty-icon">📭</div>
            <div class="empty-text">No Offers Yet</div>
            <div class="empty-desc">Buyers are reviewing your listing. Offers will come in over time based on your asking price and market conditions.</div>
          </div>
        </div>

        <!-- Offers List -->
        <div v-else class="offers-list">
          <div class="offers-heading">
            <span class="offers-count">{{ offers.length }} {{ offers.length === 1 ? 'Offer' : 'Offers' }}</span>
          </div>

          <div
            v-for="offer in offers"
            :key="offer.index"
            class="offer-card"
          >
            <div class="offer-main">
              <div class="offer-buyer">
                <div class="buyer-avatar">{{ offer.buyerName.charAt(0) }}</div>
                <div class="buyer-info">
                  <span class="buyer-name">{{ offer.buyerName }}</span>
                  <span class="offer-time">{{ formatTimeSince(offer.timestamp) }}</span>
                </div>
              </div>
              <div class="offer-amount" :class="offerColorClass(offer.value)">
                ${{ formatPrice(offer.value) }}
                <span class="offer-diff" :class="offerColorClass(offer.value)">
                  {{ offerDiffText(offer.value) }}
                </span>
              </div>
            </div>

            <div class="offer-actions">
              <button class="btn btn-accept" @click="acceptOffer(offer)">
                Accept
              </button>
              <button class="btn btn-negotiate" @click="negotiateOffer(offer)" :disabled="!offer.negotiationPossible">
                Negotiate
              </button>
              <button class="btn btn-decline" @click="declineOffer(offer)">
                Decline
              </button>
            </div>
          </div>
        </div>

    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import { lua } from '@/bridge'
import { useRoute, useRouter } from 'vue-router'
import ComputerWrapper from './ComputerWrapper.vue'

const route = useRoute()
const router = useRouter()
const garageId = route.params.garageId

const property = ref(null)
const offers = ref([])
const loading = ref(true)

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const formatTimeSince = (timestamp) => {
  if (!timestamp) return ''
  const now = Math.floor(Date.now() / 1000)
  const diff = now - timestamp
  if (diff < 60) return 'Just now'
  if (diff < 3600) return Math.floor(diff / 60) + 'm ago'
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago'
  return Math.floor(diff / 86400) + 'd ago'
}

const offerColorClass = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  const ratio = value / asking
  if (ratio >= 0.95) return 'offer-green'
  if (ratio >= 0.80) return 'offer-yellow'
  return 'offer-red'
}

const offerDiffText = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  const diff = value - asking
  const pct = Math.round((diff / asking) * 100)
  if (pct === 0) return 'at asking'
  return (pct > 0 ? '+' : '') + pct + '%'
}

const loadOffers = async () => {
  loading.value = true
  try {
    const data = await lua.career_modules_garageManager.getGarageOffersData(garageId)
    if (data) {
      property.value = data
      offers.value = data.offers || []
    }
  } catch (e) {
    // ignore
  }
  loading.value = false
}

const acceptOffer = async (offer) => {
  await lua.career_modules_garageManager.acceptOffer(garageId, offer.index)
  lua.career_career.closeAllMenus()
}

const declineOffer = async (offer) => {
  await lua.career_modules_garageManager.declineOffer(garageId, offer.index)
  await loadOffers()
}

const negotiateOffer = async (offer) => {
  await lua.career_modules_realEstateNegotiation.startNegotiateSelling(garageId, offer.index)
}

const goBack = () => {
  router.back()
}

onMounted(loadOffers)
</script>

<style scoped lang="scss">
.offers-panel {
  color: white;
  background: #0e0e0e;
  min-height: 100%;
  border-radius: 14px;
  overflow: hidden;
}

// Property Header
.property-header {
  overflow: hidden;
}

.header-preview {
  position: relative;
  width: 100%;
  height: 160px;
  background: #000;
  overflow: hidden;
}

.header-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.header-fade {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 60px;
  background: linear-gradient(to top, #0e0e0e, transparent);
  pointer-events: none;
}

.header-badges {
  position: absolute;
  top: 10px;
  left: 10px;
}

.tag {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 4px;
  letter-spacing: 0.6px;

  &.listed {
    background: rgba(249, 115, 22, 0.85);
    color: white;
  }
}

.header-body {
  padding: 16px 20px;
}

.header-name {
  font-size: 20px;
  font-weight: 700;
  margin: 0 0 12px;
}

.header-prices {
  display: flex;
  align-items: center;
  gap: 16px;
}

.price-item {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.price-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.price-value {
  font-size: 18px;
  font-weight: 800;
  color: white;
  font-variant-numeric: tabular-nums;

  &.dim {
    color: rgba(255, 255, 255, 0.5);
    font-weight: 600;
    font-size: 16px;
  }
}

.price-divider {
  width: 1px;
  height: 32px;
  background: rgba(255, 255, 255, 0.1);
}

// Offers List
.offers-list {
  padding: 0 20px;
}

.offers-heading {
  margin-bottom: 12px;
}

.offers-count {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.offer-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 10px;
  padding: 14px;
  margin-bottom: 10px;
  transition: border-color 0.2s;

  &:hover {
    border-color: rgba(255, 255, 255, 0.12);
  }
}

.offer-main {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 12px;
}

.offer-buyer {
  display: flex;
  align-items: center;
  gap: 10px;
}

.buyer-avatar {
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.08);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.6);
}

.buyer-info {
  display: flex;
  flex-direction: column;
  gap: 1px;
}

.buyer-name {
  font-size: 14px;
  font-weight: 600;
}

.offer-time {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
}

.offer-amount {
  text-align: right;
  font-size: 18px;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.offer-diff {
  display: block;
  font-size: 11px;
  font-weight: 600;
}

.offer-green {
  color: #22c55e;
}

.offer-yellow {
  color: #eab308;
}

.offer-red {
  color: #ef4444;
}

.offer-actions {
  display: flex;
  gap: 8px;
}

// Empty state
.loading-state, .empty-offers {
  padding: 40px 24px;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.empty-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 12px;
  padding: 40px 32px;
  max-width: 400px;
  margin: 0 auto;
}

.empty-icon {
  font-size: 40px;
  margin-bottom: 12px;
}

.empty-text {
  font-size: 18px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.7);
  margin-bottom: 8px;
}

.empty-desc {
  font-size: 13px;
  color: rgba(255, 255, 255, 0.35);
  line-height: 1.5;
}

// Buttons
.btn {
  padding: 8px 14px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 700;
  font-family: inherit;
  cursor: pointer;
  transition: opacity 0.15s ease, transform 0.1s ease;
  color: white;

  &:hover:not(:disabled) { opacity: 0.85; }
  &:active:not(:disabled) { transform: scale(0.97); }
  &:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
}

.btn-accept {
  flex: 1;
  background: #22c55e;
}

.btn-negotiate {
  flex: 1;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.14);
  }
}

.btn-decline {
  flex: 1;
  background: rgba(239, 68, 68, 0.12);
  color: rgba(239, 68, 68, 0.85);
  border: 1px solid rgba(239, 68, 68, 0.2);

  &:hover:not(:disabled) {
    background: rgba(239, 68, 68, 0.2);
  }
}

/* footer removed - ComputerWrapper handles back */
</style>
