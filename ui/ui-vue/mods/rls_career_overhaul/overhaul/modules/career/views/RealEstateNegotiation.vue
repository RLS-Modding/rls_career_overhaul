<!-- Real estate negotiation (buying a property / selling yours) as a chat: see NegotiationChatWindow. -->
<template>
  <div class="center-wrap">
    <NegotiationChatWindow
      ref="chatWindow"
      bng-ui-scope="vehicleNegotiation"
      v-bng-blur="1"
      :opponent-name="state.opponentName || opponent"
      :subject-name="state.propertyName || 'Property'"
      :thumbnail="state.propertyPreview"
      :fallback-icon="icons.garage01"
      :meta="propertyMeta"
      :market-value="Number(state.propertyMarketValue) || null"
      :patience="Number(state.patience) || 0"
      :quote="state.opponentQuote"
      :history="state.offerHistory || []"
      :status="state.negotiationStatus"
      :am-i-selling="!!state.amISelling"
      :their-offer="Number(state.theirOffer) || 0"
      :my-offer="state.myOffer != null ? Number(state.myOffer) : null"
      :starting-price="Number(state.startingPrice) || 0"
      :step="1000"
      :step-sizes="[1000, 10000]"
      :resolved-title="resolvedTitle"
      :resolved-title-amount="state.negotiationStatus === 'accepted' && !state.purchaseFailureReason ? Number(state.theirOffer || 0) : null"
      :resolved-text="resolvedStatusText"
      :resolved-tone="resolvedTone"
      :resolved-action="resolvedActionText"
      :resolved-amount="showStartingPriceHint ? Number(state.startingPrice) || 0 : null"
      @send="onSend"
      @accept="takeOffer"
      @walk-away="goBack"
      @close="goBack"
      @resolve="goBack" />
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, nextTick } from "vue"
import { icons } from "@/common/components/base"
import { lua } from "@/bridge"
import { vBngBlur } from "@/common/directives"
import NegotiationChatWindow from "../components/negotiation/NegotiationChatWindow.vue"
import { useUINavScope } from "@/services/uiNav"
import { useEvents } from '@/services/events'


// same UI scope name as the chat window element (bng-ui-scope below and its nav scope id)
useUINavScope("vehicleNegotiation")

const events = useEvents()
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
    return 'You negotiated a deal for ' + (state.value.propertyName || 'this property') + '.'
  }
  return ''
})

const chatWindow = ref(null)
const propertyMeta = computed(() => {
  const meta = []
  if (state.value.propertyCapacity) meta.push({ icon: icons.garage01, text: `${state.value.propertyCapacity} slots, ${state.value.propertyParkingSpots || 0} parking` })
  return meta
})
const resolvedTone = computed(() => (state.value.negotiationStatus === "accepted" ? "ok" : "bad"))
const resolvedTitle = computed(() => (state.value.negotiationStatus === "accepted" ? "Deal at" : "No deal"))
const resolvedActionText = computed(() => (state.value.amISelling ? "Continue" : "Go to Purchase Menu"))
const showStartingPriceHint = computed(() => state.value.negotiationStatus === "failed" && !state.value.amISelling)
const onSend = price => {
  offerPreview.value = price
  return submitOffer()
}

const refresh = async () => {
  const s = await lua.overhaul_career_garage_property_realEstateNegotiation.getNegotiationState()
  if (!s) {
    await lua.extensions.ui_router.navigate('phone-main')
    return
  }
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
  await lua.overhaul_career_garage_property_realEstateNegotiation.makeOffer(price)
}

const takeOffer = async () => {
  await lua.overhaul_career_garage_property_realEstateNegotiation.takeTheirOffer()
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  offerPreview.value = state.value.theirOffer
  state.value.iAccepted = true
  state.value.offerHistory.push({
    myOffer: state.value.theirOffer,
    negotiationStatus: 'accepted'
  })
}

const goBack = async (event) => {
  if (state.value.negotiationStatus !== 'accepted' && state.value.negotiationStatus !== 'failed') {
    lua.overhaul_career_garage_property_realEstateNegotiation.cancelNegotiation()
    lua.overhaul_career_career.closeAllMenus()
    if (event && event.stopPropagation) event.stopPropagation()
    return
  }

  if (state.value.amISelling && state.value.propertyId) {
    if (state.value.origin === 'phone') {
      sessionStorage.setItem('phoneRealEstateReturnTab', 'listings')
      await lua.extensions.ui_router.navigate('phone-real-estate')
    } else {
      await lua.extensions.ui_router.navigate('garage-offers', { garageId: state.value.propertyId })
    }
    if (event && event.stopPropagation) event.stopPropagation()
    return
  }

  if (state.value.negotiationStatus === 'accepted') {
    await lua.overhaul_career_garage_property_realEstateNegotiation.takeTheirOffer()
    return
  }
  lua.overhaul_career_garage_garageManager.showPurchaseGaragePrompt(state.value.propertyId)
  if (event && event.stopPropagation) event.stopPropagation()
}

const start = async () => {
  events.on('realEstateNegotiationData', handleNegotiationData)
  await refresh()

  nextTick(() => chatWindow.value?.scrollChatToBottom())
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
.center-wrap {
  width: 100%;
  height: 100%;
  min-height: 100vh; // the route container has no height of its own
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2em;
}
</style>
