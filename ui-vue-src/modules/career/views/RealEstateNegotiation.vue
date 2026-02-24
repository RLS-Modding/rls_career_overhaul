<template>
  <div class="center-wrap">
    <BngCard bng-ui-scope="vehicleNegotiation" class="negotiation-screen" v-bng-blur="1">
      <div class="header-row">
        <BngCardHeading type="ribbon">
          Negotiation with {{ state.opponentName || opponent }}
          <div v-if="state.opponentQuote" class="header-seller-info">
            "{{ state.opponentQuote }}"
          </div>
        </BngCardHeading>
        <BngButton class="close-button" @click="goBack" :accent="ACCENTS.attention" bng-no-nav="true" tabindex="-1">
          <BngBinding ui-event="menu" controller />
          <BngIcon
            type="xmarkBold"
            :color="'var(--bng-cool-gray-100)'"
          />
        </BngButton>
      </div>
      <div class="main-content">
        <div class="summary">
          <div class="vehicle-info" v-if="state.propertyName || state.propertyPreview">
            <div class="purchase-row">
              <div class="label">
                <div>{{ state.propertyName || 'Property' }}</div>
                <div v-if="state.propertyNeighborhood" class="sub-info">{{ state.propertyNeighborhood }}</div>
                <div v-if="state.propertyCapacity" class="sub-info">
                  {{ state.propertyCapacity }} slots / {{ state.propertyParkingSpots }} parking spots
                </div>
              </div>
              <div class="price">
                Est. Market:
                <div>
                  <BngUnit class="money" :money="state.propertyMarketValue || 0" />
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="offer-container">
          <NegotiationChat
            ref="negotiationChat"
            :offer-history="state.offerHistory || []"
            :negotiation-status="state.negotiationStatus"
            :starting-price="state.startingPrice || 0"
            :am-i-selling="state.amISelling"
          />
          <PriceFinder
            :offer-history="state.offerHistory || []"
            :negotiation-status="state.negotiationStatus"
            :starting-price="state.startingPrice || 0"
            :offer-preview="offerPreview || 0"
            :actual-vehicle-value="state.propertyMarketValue"
            :am-i-selling="state.amISelling"
          />
        </div>
        <div class="patience">
          <div class="bar" :class="patienceClass">
            <div class="separator" style="left: 33.0%"></div>
            <div class="separator" style="left: 66.0%"></div>
            <div class="fill" :class="patienceClass" :style="{ width: Math.max(0, Math.min(1, state.patience || 0)) * 100 + '%' }"></div>
          </div>
          <div class="label-row">
            <span>{{ opponent }}'s Patience</span>
          </div>
        </div>
        <div class="offer-controls">
          <div class="offer-controls-row" v-if="state.negotiationStatus !== 'failed' && state.negotiationStatus !== 'accepted'">
            <div class="step-buttons-group">
              <BngButton class="step step-large" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-10000)">-10000</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-5000)">-5000</BngButton>
              <BngButton class="step" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-1000)">-1000</BngButton>
              <BngButton class="step" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(1000)">+1000</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(5000)">+5000</BngButton>
              <BngButton class="step step-large" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(10000)">+10000</BngButton>
            </div>
          </div>
          <div
            class="offer-controls-row"
            v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'"
            :class="{ accepted: state.negotiationStatus === 'accepted', failed: state.negotiationStatus === 'failed' }"
          >
            <BngIcon
              :type="state.negotiationStatus === 'accepted' ? 'checkmark' : 'abandon'"
              class="resolved-negotiation-icon"
            />
            <div class="resolved-negotiation-message">{{ resolvedStatusText }}</div>
          </div>
          <div class="price-column">
            <div class="price" v-if="noDeal">NO DEAL</div>
            <div v-else class="price">{{ units.beamBucks(offerPreview || 0) }}</div>
            <div
              v-if="diffOfferPreviewToStarting !== null"
              class="diff-percent-offer-preview-to-starting"
              :class="{ positive: isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, negative: !isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, zero: diffOfferPreviewToStarting === 0, 'hidden': noDeal }"
            >
              <BngUnit
                v-if="diffOfferPreviewToStarting !== 0"
                class="money"
                :money="Math.abs(diffOfferPreviewToStarting)"
              />
              {{ diffOfferPreviewToStarting < 0 ? 'under' : diffOfferPreviewToStarting > 0 ? 'over' : 'Same as' }}
              starting price
            </div>
            <div
              v-if="diffPercentOfferPreviewToMarket !== null"
              class="diff-percent-offer-preview-to-market"
              :class="{ positive: isDiffPercentOfferPreviewToMarketGood, negative: !isDiffPercentOfferPreviewToMarketGood, 'hidden': noDeal }"
            >
              {{ Math.abs(diffPercentOfferPreviewToMarket) }}% {{ diffPercentOfferPreviewToMarket < 0 ? 'under' : 'over' }} Est. Market value
            </div>
          </div>
        </div>
      </div>
      <template #buttons>
        <div class="action-buttons wide">
          <BngButton
            v-if="state.negotiationStatus !== 'accepted' && state.negotiationStatus !== 'failed'"
            class="submit-offer"
            :disabled="state.negotiationStatus === 'counterOfferLastChance' || offerPreview == state.theirOffer || offerPreview == state.myOffer || offerDisabled"
            @click="submitOffer()"
            :accent="ACCENTS.secondary"
          >
            Submit This Offer
          </BngButton>
          <BngButton
            v-if="state.negotiationStatus !== 'accepted' && state.negotiationStatus !== 'failed'"
            class="submit-offer"
            :disabled="offerDisabled"
            show-hold
            v-bng-click="{ holdCallback: takeOffer, holdDelay: 1000, repeatInterval: 0 }"
          >
            Agree to their Price
          </BngButton>
          <BngButton
            v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'"
            class="go-back"
            :accent="ACCENTS.primary"
            @click="goBack"
          >
            {{ state.amISelling ? 'Continue' : 'Go to Purchase Menu' }}
          </BngButton>
        </div>
      </template>
    </BngCard>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, nextTick } from "vue"
import { useRouter } from "vue-router"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngBinding, BngUnit, BngIcon } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { vBngBlur, vBngClick } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useEvents } from '@/services/events'

import NegotiationChat from "@/modules/career/components/vehicleShopping/NegotiationChat.vue"
import PriceFinder from "@/modules/career/components/vehicleShopping/PriceFinder.vue"

useUINavScope("realEstateNegotiation")

const { units } = useBridge()
const events = useEvents()
const router = useRouter()

const state = ref({
  active: false,
  propertyId: null,
  propertyName: 'Property',
  propertyPreview: '',
  propertyCapacity: 0,
  propertyParkingSpots: 0,
  propertyNeighborhood: '',
  startingPrice: 0,
  patience: 0,
  myOffer: null,
  theirOffer: 0,
  status: "",
  negotiationStatus: "",
  opponentName: "Seller",
  opponentQuote: '',
  propertyMarketValue: 0,
  offerHistory: [],
  amISelling: false,
  isInsulted: false,
  origin: 'computer',
})

const opponent = computed(() => state.value.amISelling ? "Buyer" : "Seller")
const biggerIsBetter = computed(() => state.value.amISelling ? true : false)

const increaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    return (state.value.myOffer != null && (offerPreview.value >= state.value.myOffer))
  }
  return offerPreview.value >= state.value.theirOffer
})

const decreaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    return offerPreview.value <= state.value.theirOffer
  }
  return (state.value.myOffer != null && (offerPreview.value <= state.value.myOffer))
})

const offerPreview = ref(0)

const diffPercentOfferPreviewToStarting = computed(() => {
  if (state.value.startingPrice === 0) return 0
  const diff = ((offerPreview.value - state.value.startingPrice) / state.value.startingPrice) * 100
  return Math.round(diff)
})

const diffOfferPreviewToStarting = computed(() => {
  return offerPreview.value - state.value.startingPrice
})

const isDiffOfferPreviewToStartingGood = computed(() => {
  return biggerIsBetter.value ? diffOfferPreviewToStarting.value >= 0 : diffOfferPreviewToStarting.value <= 0
})

const diffPercentOfferPreviewToMarket = computed(() => {
  if (!state.value.propertyMarketValue || state.value.propertyMarketValue === 0) return null
  const diff = ((offerPreview.value - state.value.propertyMarketValue) / state.value.propertyMarketValue) * 100
  return Math.round(diff)
})

const isDiffPercentOfferPreviewToMarketGood = computed(() => {
  if (diffPercentOfferPreviewToMarket.value === null) return null
  return biggerIsBetter.value ? diffPercentOfferPreviewToMarket.value >= 0 : diffPercentOfferPreviewToMarket.value <= 0
})

const nudgeOffer = (delta) => {
  const roundedOfferPreview = Math.max(0, Math.round((offerPreview.value + delta) / 1000) * 1000)
  let min = 0
  let max = Number.POSITIVE_INFINITY

  if (state.value.amISelling) {
    min = state.value.theirOffer
    if (state.value.myOffer != null) {
      max = state.value.myOffer
    }
  } else {
    max = state.value.theirOffer
    if (state.value.myOffer != null) {
      min = state.value.myOffer
    }
  }

  offerPreview.value = Math.min(max, Math.max(min, roundedOfferPreview))
}

const offerDisabled = computed(() => {
  if (state.value.negotiationStatus === 'thinking' || state.value.negotiationStatus === 'typing' || state.value.negotiationStatus === 'accepted' || state.value.negotiationStatus === 'failed') {
    return true
  }
  return false
})

const patienceClass = computed(() => {
  const m = state.value.patience ?? 0
  if (m > 0.66) return "patience-good"
  if (m > 0.33) return "patience-mid"
  return "patience-bad"
})

const noDeal = computed(() => {
  return state.value.negotiationStatus === 'failed' && state.value.amISelling
})

const resolvedStatusText = computed(() => {
  if (state.value.negotiationStatus === 'failed') {
    if (state.value.amISelling) {
      return 'The other party ran out of patience and does not want to buy this property.'
    }
    return 'The seller ran out of patience. You can still buy at the starting price: '
  } else if (state.value.negotiationStatus === 'accepted') {
    return 'Congratulations! You\'ve successfully negotiated a deal for ' + (state.value.propertyName || 'this property') + '.'
  }
  return ''
})

const negotiationChat = ref(null)

const refresh = async () => {
  const s = await lua.career_modules_realEstateNegotiation.getNegotiationState()
  if (!s) return
  state.value = { ...state.value, ...s }

  const base = state.value.myOffer != null ? state.value.myOffer : state.value.startingPrice
  if (!Number.isNaN(Number(base))) offerPreview.value = Number(base)

  if (state.value.negotiationStatus === 'failed') {
    offerPreview.value = state.value.startingPrice
  }
}

const submitOffer = async () => {
  const price = Number(offerPreview.value)
  if (!Number.isFinite(price)) return
  await lua.career_modules_realEstateNegotiation.makeOffer(price)
}

const takeOffer = async () => {
  await lua.career_modules_realEstateNegotiation.takeTheirOffer()
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  offerPreview.value = state.value.theirOffer
  state.value.iAccepted = true
  state.value.offerHistory.push({
    myOffer: state.value.theirOffer,
    negotiationStatus: 'accepted'
  })
}

const goBack = (event) => {
  if (state.value.negotiationStatus !== 'accepted' && state.value.negotiationStatus !== 'failed') {
    lua.career_modules_realEstateNegotiation.cancelNegotiation()
    lua.career_career.closeAllMenus()
    if (event && event.stopPropagation) event.stopPropagation()
    return
  }

  if (state.value.amISelling && state.value.propertyId) {
    if (state.value.origin === 'phone') {
      router.push({ name: 'phone-real-estate', query: { tab: 'listings' } })
    } else {
      router.push({ name: 'garage-offers', params: { garageId: state.value.propertyId } })
    }
    if (event && event.stopPropagation) event.stopPropagation()
    return
  }

  lua.career_modules_garageManager.showPurchaseGaragePrompt(state.value.propertyId)
  if (event && event.stopPropagation) event.stopPropagation()
}

const start = async () => {
  events.on('realEstateNegotiationData', handleNegotiationData)
  await refresh()

  nextTick(() => {
    if (negotiationChat.value) {
      negotiationChat.value.reset()
      negotiationChat.value.scrollToBottom()
    }
  })
}

const handleNegotiationData = async () => {
  await refresh()
}

const kill = () => {
  events.off('realEstateNegotiationData', handleNegotiationData)
}

onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.negotiation-screen {
  width: 47.5rem;
  color: white;
  background-color: rgba(0, 0, 0, 0.7);

  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0.7);
  }

  :deep(.footer-container) {
    display: flex;
    flex-direction: column;
  }
}

.header-row {
  display: flex;
  flex-direction: row;
  justify-content: space-between;
  align-items: flex-end;
  padding-right: 0.5rem;
  border-bottom: 0.06rem solid rgba(255, 255, 255, 0.1);
  background-color: rgba(0, 0, 0, 0.6);
  border-radius: var(--bng-corners-2) var(--bng-corners-2) 0 0;
  min-height: 3.6rem;

  > * {
    line-height: 1.2;
  }

  .header-seller-info {
    margin-top: 0rem;
    font-size: 0.88rem;
    font-weight: 400;
    color: rgba(255, 255, 255, 0.5);
  }
}

.close-button {
  cursor: pointer;
  height: 2.25rem;
  min-width: 5.25rem;
  display: flex;
  gap: 0.5rem;
  align-items: center;
  justify-content: center;
  align-self: flex-start;
  margin-top: 0.75rem !important;
}

.center-wrap {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 5rem;
}

.main-content {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 1rem;
}

.summary {
  display: flex;
  flex-direction: column;
}

.vehicle-info {
  .purchase-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    width: 100%;
    padding: 0.1rem 0.25rem;
    border-radius: var(--bng-corners-2);
    background: linear-gradient(to right, var(--bng-cool-gray-800), rgba(var(--bng-cool-gray-850-rgb), 0));

    .label {
      text-align: left;
      flex: 1;
      min-width: 0;
      font-weight: 600;
      margin-top: 0.25rem;
    }

    .green-dot {
      width: 0.5rem;
      height: 0.5rem;
      background-color: #6ce17a;
      border-radius: 50%;
      margin-right: 0.5rem;
      content: '';
    }

    .price {
      align-self: flex-start;
      align-items: flex-end;
      flex: 0 0 auto;
      display: flex;
      flex-direction: column;
      min-width: 0;
      margin-top: -0.1rem;

      :deep(.info-item) {
        padding: 0;
      }
    }

    .sub-info {
      font-size: 0.88rem;
      color: rgba(255, 255, 255, 0.5);
      --bng-icon-color: rgba(255, 255, 255, 0.5);
      font-weight: 300;

      :deep(.value-label) {
        font-weight: 300;
      }
    }
  }
}

.offer-container {
  display: flex;
  flex-direction: row;
  gap: 0.5rem;
  height: 20rem;
}

.offer-controls {
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  gap: 0.38rem;

  .offer-controls-row {
    display: flex;
    flex-direction: row;
    justify-content: center;
    align-items: center;
    gap: 0.38rem;
    height: 4rem;
    width: 100%;
  }

  .step-buttons-group {
    display: flex;
    flex-direction: row;
    align-items: center;
    --bng-button-min-width: 5rem;
    --bng-button-max-width: 5rem;
  }

    .price-column {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.25rem;

    &.disabled {
      opacity: 0.5;
      pointer-events: none;
      text-decoration: line-through;
    }
  }

  .price {
    text-align: center;
    font-size: 2.25rem;
    font-weight: 800;
    letter-spacing: 0.06rem;
  }

  .diff-percent-offer-preview-to-starting {
    font-size: 0.88rem;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.25rem;
    min-height: 2rem;

    &.positive {
      color: #6ce17a;
      --bng-icon-color: #6ce17a;
    }

    &.negative {
      color: #ff6b6b;
      --bng-icon-color: #ff6b6b;
    }

    &.zero {
      color: rgba(255, 255, 255, 0.6);
      --bng-icon-color: rgba(255, 255, 255, 0.6);
    }

    &.hidden {
      opacity: 0;
    }
  }

  .diff-percent-offer-preview-to-market {
    font-size: 0.88rem;
    font-weight: 600;

    &.positive {
      color: #6ce17a;
    }

    &.negative {
      color: #ff6b6b;
    }

    &.hidden {
      opacity: 0;
    }
  }
}

.patience {
  display: flex;
  flex-direction: column;
  gap: 0.38rem;
  align-items: center;

  .label-row {
    display: flex;
    justify-content: space-between;
  }

  .bar {
    width: 100%;
    height: 1rem;
    background: #1b2a3a;
    border-radius: 0.5rem;
    overflow: hidden;
    position: relative;

    &.patience-good {
      border: 1px solid rgba(var(--bng-add-green-400-rgb), 0.3);
    }

    &.patience-mid {
      border: 1px solid rgba(var(--bng-ter-yellow-300-rgb), 0.5);
    }

    &.patience-bad {
      border: 1px solid rgba(var(--bng-add-red-500-rgb), 0.4);
    }
  }

  .separator {
    position: absolute;
    top: 0;
    width: 1px;
    height: 100%;
    background: rgba(255, 255, 255, 0.5);
    z-index: 2;
  }

  .fill {
    height: 100%;
    position: relative;
    z-index: 1;
    transition: width 1s ease-in-out, background-color 1s ease-out;

    &.patience-good {
      background-color: var(--bng-add-green-400);
    }

    &.patience-mid {
      background-color: var(--bng-ter-yellow-300);
    }

    &.patience-bad {
      background-color: var(--bng-add-red-500);
    }
  }
}

.resolved-negotiation-message {
  font-size: 1.2rem;
  text-align: center;
  padding: 0.5rem 0;
}

.accepted {
  padding: 0.5rem 5rem;
  color: var(--bng-add-green-400);
  --bng-icon-color: var(--bng-add-green-400);
  border-radius: 1rem;
  background: rgba(var(--bng-add-green-400-rgb), 0.2);
}

.failed {
  padding: 0.5rem 5rem;
  color: var(--bng-add-red-400);
  --bng-icon-color: var(--bng-add-red-400);
  border-radius: 1rem;
  background: rgba(var(--bng-add-red-400-rgb), 0.2);
}

.resolved-negotiation-icon {
  font-size: 3rem;
  margin-right: 0.5rem;
}

.label {
  font-weight: bold;
}

.value {
  text-align: right;
}

.action-buttons {
  display: flex;
  justify-content: flex-end;

  .submit-offer {
    background: #ff7a1a;
    border-color: #ff7a1a;
    font-weight: 800;
  }

  &.wide {
    width: 100%;

    > * {
      flex: 1;
      max-width: none;
    }
  }
}

.patience-good {
  color: rgb(51, 255, 51);
}

.patience-mid {
  color: rgb(255, 255, 51);
}

.patience-bad {
  color: rgb(255, 51, 51);
}
</style>
