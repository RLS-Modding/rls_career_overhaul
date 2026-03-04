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
        <!-- Top summary could show vehicle info when available -->
        <div class="summary">
          <div class="vehicle-info" v-if="state.vehicleNiceName || state.vehicleThumbnail">
            <!--
            <img
              v-if="state.vehicleThumbnail"
              class="vehicle-thumb"
              :src="state.vehicleThumbnail"
              :alt="state.vehicleNiceName || 'Vehicle thumbnail'"
            >
          -->
            <div class="purchase-row">
              <div class="label">
                <div>{{ state.vehicleNiceName || 'Vehicle' }}</div>
                <div class="sub-info">{{ units.buildString("length", state.vehicleMileage, 0) }}</div>
              </div>
              <div class="price">
                <!--<BngUnit class="money" :money="state.startingPrice || 0" />-->
                Est. Market:
                <div>
                  <BngUnit class="money" :money="state.actualVehicleValue || 0" />
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Two column panels - ->
        <div class="columns">
          <div class="panel left">
            <div class="panel-title">Your offer</div>
            <div class="info-row"><span class="row-label">Your Current Offer</span><span class="row-value">{{ state.myOffer != null ? units.beamBucks(state.myOffer) : "(Not set)" }}</span></div>
          </div>
          <div class="panel right">
            <div class="panel-title">{{ opponent }}'s offer</div>
            <div class="info-row"><span class="row-label">Their current offer</span><span class="row-value highlight">{{ units.beamBucks(state.theirOffer || 0) }}</span></div>
            <div class="info-row small"><span class="row-label">Difference From Starting Price</span><span class="row-value" :class="{pos: isDiffTheirOfferToStartingGood, neg: !isDiffTheirOfferToStartingGood  }">{{ units.beamBucks(diffTheirOfferToStarting) }}</span></div>
          </div>
        </div>
        -->

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
            :actual-vehicle-value="state.actualVehicleValue"
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


        <!-- Big price offer-controls -->
        <div class="offer-controls">
          <div class="offer-controls-row" v-if="state.negotiationStatus !== 'failed' && state.negotiationStatus !== 'accepted'">
            <div class="step-buttons-group">
              <BngButton class="step step-large" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-5000)">-5000</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-500)">-500</BngButton>
              <BngButton class="step" :disabled="offerDisabled || decreaseOfferDisabled" @click="nudgeOffer(-50)">-50</BngButton>

              <BngButton class="step" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(50)">+50</BngButton>
              <BngButton class="step step-medium" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(500)">+500</BngButton>
              <BngButton class="step step-large" :disabled="offerDisabled || increaseOfferDisabled" @click="nudgeOffer(5000)">+5000</BngButton>
            </div>
          </div>

          <div class="offer-controls-row" v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'" :class="{ accepted: state.negotiationStatus === 'accepted', failed: state.negotiationStatus === 'failed' }">
            <BngIcon :type="state.negotiationStatus === 'accepted' ? 'checkmark' : 'abandon'" class="resolved-negotiation-icon" />

            <div class="resolved-negotiation-message" >{{resolvedStatusText}}</div>
          </div>

          <div class="price-column" >
            <div class="price" v-if="noDeal">
              NO DEAL
            </div>
            <div v-else class="price">
              {{ units.beamBucks(offerPreview || 0) }}
            </div>
            <div v-if="diffOfferPreviewToStarting !== null" class="diff-percent-offer-preview-to-starting" :class="{ positive: isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, negative: !isDiffOfferPreviewToStartingGood && diffOfferPreviewToStarting !== 0, zero: diffOfferPreviewToStarting === 0, 'hidden': noDeal }">
              <BngUnit v-if="diffOfferPreviewToStarting !== 0" class="money" :money="Math.abs(diffOfferPreviewToStarting)" /> {{ diffOfferPreviewToStarting < 0 ? 'under' : diffOfferPreviewToStarting > 0 ? 'over' : 'Same as' }} starting price
            </div>
            <div v-if="diffPercentOfferPreviewToMarket !== null" class="diff-percent-offer-preview-to-market" :class="{ positive: isDiffPercentOfferPreviewToMarketGood, negative: !isDiffPercentOfferPreviewToMarketGood, 'hidden': noDeal }">
              {{ Math.abs(diffPercentOfferPreviewToMarket) }}% {{ diffPercentOfferPreviewToMarket < 0 ? 'under' : 'over' }} Est. Market value
            </div>
          </div>
        </div>

        <!-- Status + primary action box -->
        <!--
        <div class="decision-box" :class="{ accepted: state.negotiationStatus === 'accepted', rejected: isRejected }">
          <div class="status-line">
            <span class="label">Status: </span>
            <span class="value">{{ statusText }}</span>
            <span v-if="state.negotiationStatus === 'thinking'" class="spinner" aria-label="Thinking"></span>
          </div>
          <div class="actions">
            <div v-if="state.negotiationStatus === 'accepted' || state.negotiationStatus === 'counterOffer' || state.negotiationStatus === 'counterOfferLastChance'">
              {{ units.beamBucks(state.theirOffer || 0) }}
              <BngButton :accent="ACCENTS.secondary" @click="takeOffer">Accept</BngButton>
            </div>
          </div>
        </div>
        -->
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
            :disabled="state.negotiationStatus === 'counterOfferLastChance' || offerDisabled"
            show-hold
            v-bng-click="{ holdCallback: takeOffer, holdDelay: 1000, repeatInterval: 0 }"
          >
            Agree to their Price
          </BngButton>

          <BngButton v-if="state.negotiationStatus === 'failed' || state.negotiationStatus === 'accepted'" class="go-back" :accent="ACCENTS.primary" @click="goBack">
            {{ state.amISelling ? 'Continue' : 'Go to Purchase Screen' }}
          </BngButton>
        </div>
      </template>
    </BngCard>
  </div>

</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch, nextTick } from "vue"
import { useRouter } from "vue-router"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngBinding, BngUnit, BngIcon } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { vBngOnUiNav, vBngBlur, vBngClick } from "@/common/directives"
import { useUINavScope } from "@/services/uiNav"
import { useEvents } from '@/services/events'
import NegotiationChat from "@/modules/career/components/vehicleShopping/NegotiationChat.vue"
import PriceFinder from "@/modules/career/components/vehicleShopping/PriceFinder.vue"
useUINavScope("vehicleNegotiation")

const { units } = useBridge()
const events = useEvents()
const router = useRouter()

const state = ref({
  active: false,
  startingPrice: 0,
  patience: 0,
  myOffer: null,
  theirOffer: 0,
  thinking: false,
  status: "",
  negotiationStatus: "",
  opponentName: "",
  vehicleNiceName: "",
  vehicleThumbnail: "",
  amISelling: false
})

const opponent = computed(() => state.value.amISelling ? "Buyer" : "Seller")
const biggerIsBetter = computed(() => state.value.amISelling ? true : false)

const increaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    return (state.value.myOffer != null && (offerPreview.value >= state.value.myOffer))
  } else {
    return offerPreview.value >= state.value.theirOffer
  }
})

const decreaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    console.log("decreaseOfferDisabled", offerPreview.value, state.value.theirOffer)
    return offerPreview.value <= state.value.theirOffer
  } else {
    return (state.value.myOffer != null && (offerPreview.value <= state.value.myOffer))
  }
})

const offerPreview = ref(0)
const stepSize = computed(() => {
  const baseStep = state.value.startingPrice / 500
  return Math.round(baseStep / 5) * 5
})

const diffPercentOfferPreviewToStarting = computed(() => {
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
  if (!state.value.actualVehicleValue || state.value.actualVehicleValue === 0) return null
  const diff = ((offerPreview.value - state.value.actualVehicleValue) / state.value.actualVehicleValue) * 100
  return Math.round(diff)
})

const isDiffPercentOfferPreviewToMarketGood = computed(() => {
  if (diffPercentOfferPreviewToMarket.value === null) return null
  return biggerIsBetter.value ? diffPercentOfferPreviewToMarket.value >= 0 : diffPercentOfferPreviewToMarket.value <= 0
})

const diffTheirOfferToStarting = computed(() => {
  const diff = state.value.theirOffer - state.value.startingPrice
  return diff
})

const isDiffTheirOfferToStartingGood = computed(() => {
  return biggerIsBetter.value ? diffTheirOfferToStarting.value >= 0 : diffTheirOfferToStarting.value <= 0
})

const nudgeOffer = (delta) => {
  const roundedOfferPreview = Math.max(0, Math.round((offerPreview.value + delta) / 50) * 50)

  let min = 0
  let max = Number.POSITIVE_INFINITY

  if (state.value.amISelling) {
    min = state.value.theirOffer
    if ( state.value.myOffer != null ) {
      max = state.value.myOffer
    }
  } else {
    max = state.value.theirOffer
    if ( state.value.myOffer != null ) {
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

// Derived status helpers for clearer UI logic (use negotiationStatus from Lua)
const isRejected = computed(() => state.value.negotiationStatus === 'failed')

// Human-readable status label from negotiationStatus
const statusText = computed(() => {
  switch (String(state.value.negotiationStatus || '')) {
    case 'counterOffer':
      return 'Counter offer'
    case 'counterOfferLastChance':
      return 'Last chance counter offer'
    case 'accepted':
      return 'Accepted'
    case 'failed':
      return 'Negotiation failed'
    case 'refused':
      return 'Offer refused'
    case 'initial':
      return 'Initial offer'
    case 'thinking':
      return 'Thinking'
    case 'typing':
      return 'Typing...'
    default:
      return ''
  }
})

const resolvedStatusText = computed(() => {
  if (state.value.negotiationStatus === 'failed') {
    if (state.value.amISelling) {
      return 'The other party ran out of patience and does not want to buy this vehicle.'
    } else {
      return 'The other party ran out of patience. You can still buy the vehicle at the starting price: '
    }
  } else if (state.value.negotiationStatus === 'accepted') {
    return 'Congratulations! You\'ve successfully negotiatied a deal with ' + state.value.opponentName +'.'
  }
  return ''
})

const negotiationChat = ref(null)


const refresh = async () => {
  const s = await lua.career_modules_marketplace.getNegotiationState()
  if (!s) {
    lua.career_career.closeAllMenus()
    return
  }
  state.value = s
  const base = state.value.myOffer != null ? state.value.myOffer : state.value.startingPrice
  if (!Number.isNaN(Number(base))) offerPreview.value = Number(base)

  if (state.value.negotiationStatus === 'failed') {
    offerPreview.value = state.value.startingPrice
  }

}

const submitOffer = async () => {
  const price = Number(offerPreview.value)
  if (!Number.isFinite(price)) return
  await lua.career_modules_marketplace.makeNegotiationOffer(price)
}

const takeOffer = async () => {
  //if (state.value.amISelling) {
    await lua.career_modules_marketplace.takeTheirOffer()
  //}
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  offerPreview.value = state.value.theirOffer
  state.value.iAccepted = true

  //insert a new offer history item with the their offer and the negotiation status 'accepted'
  state.value.offerHistory.push({
    myOffer: state.value.theirOffer,
    negotiationStatus: 'accepted'
  })
}

const cancel = async () => {
  if(state.value.negotiationStatus !== 'accepted')
    await lua.career_modules_marketplace.cancelNegotiation()
}

const goBack = (event) => {
  router.back()
  if(state.value.negotiationStatus === 'accepted' && !state.value.iAccepted)
    lua.career_modules_marketplace.takeTheirOffer()
  cancel()
  if (event && event.stopPropagation) event.stopPropagation()
}

const start = async () => {
  await refresh()
  nextTick(() => {
    if (negotiationChat.value) {
      negotiationChat.value.reset()
      negotiationChat.value.scrollToBottom()
    }
  })
}

const kill = async () => {
  events.off("negotiationData")
}

// Lua events
events.on("negotiationData", data => {
  refresh()
})


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

.thinking {
  font-size: 1.2rem;
  padding: 1rem 0;
}

.spinner {
  display: inline-block;
  width: 1rem;
  height: 1rem;
  margin-left: 0.5rem;
  border: 0.13rem solid rgba(255, 255, 255, 0.3);
  border-top-color: #ffffff;
  border-radius: 50%;
  animation: spinner-rotate 0.8s linear infinite;
  vertical-align: middle;
}

@keyframes spinner-rotate {
  to {
    transform: rotate(360deg);
  }
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

  .title {
    font-weight: 800;
    letter-spacing: 0.03rem;
  }
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

.columns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
}

.panel {
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(13, 21, 31, 0.6);
  border-radius: 0.63rem;
  padding: 1rem 1rem;
}

.panel-title {
  color: #ff9b3a;
  font-weight: 700;
  margin-bottom: 0.63rem;
}

.info-row {
  display: flex;
  justify-content: space-between;
  padding: 0.38rem 0;

  &.small {
    font-size: 0.9rem;
    opacity: 0.9;
  }
}

.row-label {
  color: #9fb0c0;
}

.row-value {
  font-weight: 700;

  &.highlight {
    color: #ffb25e;
  }

  &.pos {
    color: #6ce17a;
  }

  &.neg {
    color: #ff6b6b;
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
    ;

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

.decision-box {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: center;
  gap: 0.75rem;
  padding: 0.88rem 1rem;
  border: 0.13rem solid rgba(255, 255, 255, 0.18);
  background: rgba(13, 21, 31, 0.85);
  border-radius: 0.75rem;
  margin-top: 0.5rem;

  &.accepted {
    border-color: #6ce17a;
    box-shadow: 0 0 0 0.13rem rgba(108, 225, 122, 0.2) inset;
  }

  &.rejected {
    border-color: #ff6b6b;
    box-shadow: 0 0 0 0.13rem rgba(255, 107, 107, 0.15) inset;
  }

  .status-line {
    font-size: 1.05rem;
  }

  .actions {
    display: flex;
    gap: 0.63rem;
  }

  .accept-offer {
    background: #6ce17a;
    border-color: #6ce17a;
    color: #0b1b10;
    font-weight: 900;
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


