<template>
  <LayoutSingle class="negotiation-layout">
    <div class="negotiation-container">
      <BngCard class="negotiation-card">
        <!-- Property Info Header -->
        <div class="property-info">
          <div class="property-preview-thumbnail" v-if="propertyPreview">
            <img :src="propertyPreview" alt="Property" class="thumbnail-img" />
          </div>
          <div class="property-details-header">
            <h2 class="property-title">{{ propertyName }}</h2>
            <div class="listed-price-label">Listed: ${{ formatPrice(startingPrice) }}</div>
          </div>
        </div>

        <hr class="divider" />

        <!-- Negotiation State -->
        <div class="negotiation-state">
          <div class="seller-info">
            <div class="seller-name">{{ opponentName }}</div>
            <div class="seller-quote">"{{ opponentQuote }}"</div>
          </div>

          <div class="offer-grid">
            <div class="offer-item">
              <div class="offer-label">Their Current Offer</div>
              <div class="offer-value seller-offer">${{ formatPrice(theirOffer) }}</div>
            </div>
            <div class="offer-item">
              <div class="offer-label">Your Current Offer</div>
              <div class="offer-value buyer-offer">
                {{ myOffer ? '$' + formatPrice(myOffer) : 'Not set' }}
              </div>
            </div>
          </div>

          <!-- Patience Meter -->
          <div class="patience-section">
            <div class="patience-label">Seller Patience</div>
            <div class="patience-bar-container">
              <div 
                class="patience-bar" 
                :class="patienceClass"
                :style="{ width: patiencePercent + '%' }"
              ></div>
            </div>
          </div>

          <!-- Status Messages -->
          <div class="status-message" v-if="statusMessage">
            <div :class="['status-text', statusClass]">{{ statusMessage }}</div>
          </div>

          <!-- Success Screen -->
          <div class="success-screen" v-if="status === 'accepted'">
            <div class="success-icon">✓</div>
            <div class="success-title">Deal Accepted!</div>
            <div class="savings-info">
              <div class="savings-amount">You saved ${{ formatPrice(savings) }}</div>
              <div class="savings-percent">({{ savingsPercent.toFixed(1) }}% off listed price)</div>
            </div>
            <div class="feedback-message" :class="feedbackClass">{{ feedbackMessage }}</div>
          </div>

          <!-- Offer Input (only if negotiation is active and not accepted/failed) -->
          <div class="offer-input-section" v-if="canMakeOffer">
            <label class="input-label">Make Your Offer</label>
            <div class="offer-input-group">
              <input 
                type="number" 
                v-model.number="playerOfferInput"
                :min="0"
                :max="theirOffer"
                :disabled="isProcessing"
                class="offer-input"
                placeholder="Enter amount"
              />
              <BngButton
                @click="submitOffer"
                :accent="ACCENTS.primary"
                :disabled="!isValidOffer || isProcessing"
                class="make-offer-btn"
              >
                Make Offer
              </BngButton>
            </div>
            <div class="offer-hint" v-if="offerHint">{{ offerHint }}</div>
          </div>

          <!-- Action Buttons -->
          <div class="action-buttons">
            <BngButton
              v-if="status === 'counterOffer' || status === 'counterOfferLastChance'"
              @click="acceptTheirOffer"
              :accent="ACCENTS.primary"
              :disabled="isProcessing"
              class="action-btn"
            >
              Accept Their Offer
            </BngButton>
            <BngButton
              v-if="status === 'accepted' && !isProcessing"
              @click="acceptTheirOffer"
              :accent="ACCENTS.primary"
              class="action-btn"
            >
              Buy Now
            </BngButton>
            <BngButton
              v-if="(status === 'counterOffer' || status === 'counterOfferLastChance' || status === 'accepted') && !isProcessing"
              @click="freezePrice"
              :accent="ACCENTS.secondary"
              class="action-btn freeze-btn"
            >
              Price Freeze
            </BngButton>
            <BngButton
              v-if="status !== 'accepted' && status !== 'failed'"
              @click="cancelNegotiation"
              :accent="ACCENTS.secondary"
              class="action-btn"
            >
              Walk Away
            </BngButton>
            <BngButton
              v-if="status === 'accepted' || status === 'failed'"
              @click="close"
              :accent="ACCENTS.secondary"
              class="action-btn"
            >
              Close
            </BngButton>
          </div>
        </div>
      </BngCard>
    </div>
  </LayoutSingle>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { lua, useBridge } from '@/bridge'
import {
  BngButton,
  ACCENTS,
  BngCard
} from '@/common/components/base'
import { LayoutSingle } from '@/common/layouts'

const { events } = useBridge()

// Negotiation state
const active = ref(false)
const propertyId = ref('')
const propertyName = ref('Property')
const propertyPreview = ref('')
const startingPrice = ref(0)
const patience = ref(1.0)
const myOffer = ref(null)
const theirOffer = ref(0)
const status = ref('initial')
const opponentName = ref('Seller')
const opponentQuote = ref('')
const propertyMarketValue = ref(0)

// UI state
const playerOfferInput = ref(null)
const isProcessing = ref(false)

const handleNegotiationData = (data) => {
  if (!data) return
  
  active.value = data.active || false
  propertyId.value = data.propertyId || ''
  propertyName.value = data.propertyName || 'Property'
  propertyPreview.value = data.propertyPreview || ''
  startingPrice.value = data.startingPrice || 0
  patience.value = data.patience || 0
  myOffer.value = data.myOffer
  theirOffer.value = data.theirOffer || 0
  status.value = data.status || 'initial'
  opponentName.value = data.opponentName || 'Seller'
  opponentQuote.value = data.opponentQuote || ''
  propertyMarketValue.value = data.propertyMarketValue || 0
  
  // Reset processing flag when status changes
  if (status.value !== 'thinking' && status.value !== 'typing') {
    isProcessing.value = false
  }
}

onMounted(() => {
  events.on('realEstateNegotiationData', handleNegotiationData)
  
  // Request initial state
  lua.career_modules_realEstateNegotiation.getNegotiationState().then(handleNegotiationData)
})

onUnmounted(() => {
  events.off('realEstateNegotiationData', handleNegotiationData)
})

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const patiencePercent = computed(() => {
  return Math.max(0, Math.min(100, patience.value * 100))
})

const patienceClass = computed(() => {
  if (patience.value > 0.6) return 'patience-high'
  if (patience.value > 0.3) return 'patience-medium'
  return 'patience-low'
})

const canMakeOffer = computed(() => {
  return status.value !== 'accepted' && 
         status.value !== 'failed' && 
         status.value !== 'thinking' && 
         status.value !== 'typing'
})

const isValidOffer = computed(() => {
  if (!playerOfferInput.value) return false
  if (playerOfferInput.value <= 0) return false
  if (playerOfferInput.value > theirOffer.value) return false
  if (myOffer.value && playerOfferInput.value >= myOffer.value) return false
  return true
})

const offerHint = computed(() => {
  if (!playerOfferInput.value) return ''
  if (playerOfferInput.value > theirOffer.value) return 'Offer cannot be higher than their current offer'
  if (myOffer.value && playerOfferInput.value >= myOffer.value) return 'Offer must be lower than your previous offer'
  return ''
})

const statusMessage = computed(() => {
  switch (status.value) {
    case 'thinking':
      return 'Seller is considering your offer...'
    case 'typing':
      return 'Seller is typing...'
    case 'failed':
      return 'Negotiation failed. The seller has walked away.'
    case 'counterOfferLastChance':
      return '⚠️ Final offer! Seller is losing patience.'
    default:
      return ''
  }
})

const statusClass = computed(() => {
  switch (status.value) {
    case 'failed':
      return 'status-error'
    case 'counterOfferLastChance':
      return 'status-warning'
    default:
      return 'status-info'
  }
})

const savings = computed(() => {
  if (status.value !== 'accepted' || !myOffer.value) return 0
  return startingPrice.value - myOffer.value
})

const savingsPercent = computed(() => {
  if (status.value !== 'accepted' || !myOffer.value || startingPrice.value === 0) return 0
  return (savings.value / startingPrice.value) * 100
})

const feedbackMessage = computed(() => {
  const percent = savingsPercent.value
  if (percent >= 8) return 'Excellent negotiation!'
  if (percent >= 5) return 'Good deal!'
  if (percent >= 2) return 'Fair price.'
  return 'You paid close to asking price.'
})

const feedbackClass = computed(() => {
  const percent = savingsPercent.value
  if (percent >= 8) return 'feedback-excellent'
  if (percent >= 5) return 'feedback-good'
  if (percent >= 2) return 'feedback-fair'
  return 'feedback-okay'
})

const submitOffer = () => {
  if (!isValidOffer.value) return
  
  isProcessing.value = true
  lua.career_modules_realEstateNegotiation.makeOffer(playerOfferInput.value)
  playerOfferInput.value = null
}

const acceptTheirOffer = () => {
  isProcessing.value = true
  lua.career_modules_realEstateNegotiation.takeTheirOffer()
}

const freezePrice = () => {
  isProcessing.value = true
  lua.career_modules_realEstateNegotiation.freezeCurrentOffer()
}

const cancelNegotiation = () => {
  lua.career_modules_realEstateNegotiation.cancelNegotiation()
  lua.career_career.closeAllMenus()
}

const close = () => {
  lua.career_career.closeAllMenus()
}
</script>

<style scoped lang="scss">
.negotiation-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: white;
}

.negotiation-container {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  z-index: 100;
  overflow-y: auto;
  padding: 2em;
}

.negotiation-card {
  :deep(.card-cnt) {
    background: rgba(0, 0, 0, 0.95);
    border-radius: 0.75em;
    padding: 1.5em;
    box-shadow: 0 0 40px rgba(0, 0, 0, 0.8);
    border: 1px solid rgba(255, 255, 255, 0.2);
    max-width: 700px;
    width: 100%;
  }
}

.property-info {
  display: flex;
  gap: 1em;
  align-items: center;
  margin-bottom: 1em;
}

.property-preview-thumbnail {
  width: 120px;
  height: 80px;
  border-radius: 0.5em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.05);
  flex-shrink: 0;
}

.thumbnail-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.property-details-header {
  flex: 1;
}

.property-title {
  font-size: 1.5em;
  font-weight: 600;
  margin: 0 0 0.25em 0;
}

.listed-price-label {
  font-size: 1em;
  color: rgba(255, 255, 255, 0.6);
}

.divider {
  border: 0;
  height: 1px;
  background: rgba(255, 255, 255, 0.1);
  margin: 1em 0;
}

.negotiation-state {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.seller-info {
  background: rgba(255, 255, 255, 0.05);
  padding: 1em;
  border-radius: 0.5em;
  border-left: 3px solid rgba(100, 149, 237, 0.5);
}

.seller-name {
  font-weight: 600;
  font-size: 1.1em;
  margin-bottom: 0.5em;
  color: rgba(100, 149, 237, 1);
}

.seller-quote {
  font-style: italic;
  color: rgba(255, 255, 255, 0.8);
}

.offer-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1em;
}

.offer-item {
  background: rgba(255, 255, 255, 0.05);
  padding: 1em;
  border-radius: 0.5em;
}

.offer-label {
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.6);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.5em;
}

.offer-value {
  font-size: 1.5em;
  font-weight: 700;
}

.seller-offer {
  color: #ff9800;
}

.buyer-offer {
  color: #4caf50;
}

.patience-section {
  margin-top: 0.5em;
}

.patience-label {
  font-size: 0.9em;
  color: rgba(255, 255, 255, 0.7);
  margin-bottom: 0.5em;
}

.patience-bar-container {
  width: 100%;
  height: 20px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  overflow: hidden;
}

.patience-bar {
  height: 100%;
  transition: width 0.3s ease, background-color 0.3s ease;
  border-radius: 10px;
}

.patience-high {
  background: linear-gradient(90deg, #4caf50, #8bc34a);
}

.patience-medium {
  background: linear-gradient(90deg, #ff9800, #ffb74d);
}

.patience-low {
  background: linear-gradient(90deg, #f44336, #e57373);
}

.status-message {
  padding: 1em;
  border-radius: 0.5em;
  text-align: center;
  font-weight: 500;
}

.status-info {
  background: rgba(33, 150, 243, 0.2);
  color: rgba(100, 181, 246, 1);
}

.status-warning {
  background: rgba(255, 152, 0, 0.2);
  color: rgba(255, 183, 77, 1);
}

.status-error {
  background: rgba(244, 67, 54, 0.2);
  color: rgba(239, 83, 80, 1);
}

.success-screen {
  background: rgba(76, 175, 80, 0.1);
  border: 2px solid rgba(76, 175, 80, 0.5);
  border-radius: 0.75em;
  padding: 2em;
  text-align: center;
}

.success-icon {
  font-size: 4em;
  color: #4caf50;
  margin-bottom: 0.25em;
}

.success-title {
  font-size: 1.8em;
  font-weight: 700;
  color: #4caf50;
  margin-bottom: 1em;
}

.savings-info {
  margin-bottom: 1em;
}

.savings-amount {
  font-size: 1.5em;
  font-weight: 700;
  color: #4caf50;
}

.savings-percent {
  font-size: 1.1em;
  color: rgba(255, 255, 255, 0.7);
}

.feedback-message {
  font-size: 1.2em;
  font-weight: 600;
  margin-top: 1em;
}

.feedback-excellent {
  color: #4caf50;
}

.feedback-good {
  color: #8bc34a;
}

.feedback-fair {
  color: #ffb74d;
}

.feedback-okay {
  color: rgba(255, 255, 255, 0.7);
}

.offer-input-section {
  margin-top: 1em;
}

.input-label {
  display: block;
  font-size: 0.9em;
  font-weight: 600;
  margin-bottom: 0.5em;
  color: rgba(255, 255, 255, 0.8);
}

.offer-input-group {
  display: flex;
  gap: 0.75em;
}

.offer-input {
  flex: 1;
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 0.5em;
  padding: 0.75em 1em;
  color: white;
  font-size: 1.1em;
  font-weight: 600;

  &:focus {
    outline: none;
    border-color: rgba(100, 149, 237, 0.5);
    background: rgba(255, 255, 255, 0.15);
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.make-offer-btn {
  flex-shrink: 0;
}

.offer-hint {
  margin-top: 0.5em;
  font-size: 0.85em;
  color: rgba(255, 152, 0, 0.9);
}

.action-buttons {
  display: flex;
  gap: 0.75em;
  margin-top: 1.5em;
  flex-wrap: wrap;
}

.action-btn {
  flex: 1;
  min-width: 150px;
}

/* Remove number input arrows */
input[type="number"]::-webkit-inner-spin-button,
input[type="number"]::-webkit-outer-spin-button {
  -webkit-appearance: none;
  margin: 0;
}

input[type="number"] {
  -moz-appearance: textfield;
}
</style>
