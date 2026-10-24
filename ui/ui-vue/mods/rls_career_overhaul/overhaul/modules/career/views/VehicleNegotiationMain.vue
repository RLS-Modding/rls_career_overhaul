<!-- Vehicle negotiation (buying from a seller / selling to a buyer) as a chat: see NegotiationChatWindow. -->
<template>
  <div class="center-wrap" v-bng-scoped-nav="{ scopeId: 'root', activateOnMount: false }">
    <NegotiationChatWindow
      ref="chatWindow"
      scope-id="vehicle-negotiation"
      bng-ui-scope="vehicle-negotiation"
      v-bng-blur="1"
      :opponent-name="state.opponentName || opponent"
      :subject-name="state.vehicleNiceName || 'Vehicle'"
      :thumbnail="state.vehicleThumbnail"
      :fallback-icon="icons.car"
      :meta="vehicleMeta"
      :market-value="state.hideMarketValue ? null : Number(state.actualVehicleValue) || 0"
      :patience="Number(state.patience) || 0"
      :quote="state.opponentQuote"
      :history="state.offerHistory || []"
      :status="state.negotiationStatus"
      :am-i-selling="!!state.amISelling"
      :their-offer="Number(state.theirOffer) || 0"
      :my-offer="state.myOffer != null ? Number(state.myOffer) : null"
      :starting-price="Number(state.startingPrice) || 0"
      :has-visible-their-offer="state.hasVisibleTheirOffer !== false"
      :awaiting-opening="awaitingOpeningOffer"
      :step="50"
      :busy="acceptancePending"
      :resolved-title="resolvedTitle"
      :resolved-title-amount="state.negotiationStatus === 'accepted' && !state.purchaseFailureReason ? Number(state.theirOffer || 0) : null"
      :resolved-text="resolvedStatusText"
      :resolved-tone="resolvedTone"
      :resolved-action="resolvedActionText"
      :resolved-amount="showStartingPriceHint ? Number(state.startingPrice) || 0 : null"
      @send="onSend"
      @accept="takeOffer"
      @walk-away="closeNegotiation"
      @close="closeNegotiation"
      @resolve="goBack" />
  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { computed, onMounted, onUnmounted, ref, watch, nextTick } from "vue"
import { icons } from "@/common/components/base"
import { lua, useBridge } from "@/bridge"
import { useCefTyping } from "../composables/useCefTyping"
import { formatOdometer } from "../utils/units"
import { vBngBlur, vBngScopedNav } from "@/common/directives"
import NegotiationChatWindow from "../components/negotiation/NegotiationChatWindow.vue"
import { useUINavScope } from "@/services/uiNav"
import { useEvents } from '@/services/events'
import { useRouteReady } from "@/services/routeReadiness"
useUINavScope("vehicle-negotiation")

const { units } = useBridge()
const events = useEvents()
const cefTyping = useCefTyping()

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
  amISelling: false,
  hideMarketValue: false,
  playerStartsNegotiation: false,
  hasVisibleTheirOffer: true,
  purchaseAfterAccept: false,
  purchaseFailureReason: null,
  returnRoute: "play",
  returnParams: {}
})

const opponent = computed(() => state.value.amISelling ? "Buyer" : "Seller")
const biggerIsBetter = computed(() => state.value.amISelling ? true : false)

const increaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {
    return (state.value.myOffer != null && (offerPreview.value >= state.value.myOffer))
  } else {
    if (!state.value.hasVisibleTheirOffer) return false
    return offerPreview.value >= state.value.theirOffer
  }
})

const decreaseOfferDisabled = computed(() => {
  if (state.value.amISelling) {

    return offerPreview.value <= state.value.theirOffer
  } else {
    if (!state.value.hasVisibleTheirOffer) {
      return state.value.myOffer != null && offerPreview.value <= state.value.myOffer
    }
    return (state.value.myOffer != null && (offerPreview.value <= state.value.myOffer))
  }
})

const offerPreview = ref(0)
const openingOffer = ref(null)
const openingOfferText = ref("0")
const openingOfferTouched = ref(false)
// A spawned listing must sync its live part conditions before Lua can finish the sale.
// Lock every action that could submit or leave the negotiation until that result arrives.
const acceptancePending = ref(false)
const awaitingOpeningOffer = computed(() => {
  return state.value.playerStartsNegotiation && state.value.myOffer == null && !state.value.hasVisibleTheirOffer && state.value.negotiationStatus !== 'failed' && state.value.negotiationStatus !== 'accepted'
})
const openingOfferDisabled = computed(() => !(Number(openingOffer.value) > 0) || offerDisabled.value)
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
    max = state.value.hasVisibleTheirOffer ? state.value.theirOffer : Number.POSITIVE_INFINITY
    if ( state.value.myOffer != null ) {
      min = state.value.myOffer
    }
  }

  offerPreview.value = Math.min(max, Math.max(min, roundedOfferPreview))
}

const nudgeOpeningOffer = delta => {
  const current = Number(openingOffer.value) || 0
  openingOfferTouched.value = true
  openingOffer.value = Math.max(0, Math.round((current + delta) / 50) * 50)
  openingOfferText.value = String(openingOffer.value)
  offerPreview.value = openingOffer.value
}

const onOpeningOfferInput = event => {
  const digits = String(event.target.value || "").replace(/[^\d]/g, "")
  openingOfferText.value = digits
  openingOffer.value = digits === "" ? null : Number(digits)
  openingOfferTouched.value = true
  offerPreview.value = Number(openingOffer.value) || 0
}

const onOpeningInputFocus = event => {
  cefTyping.onFocus()
  if (event?.target?.select) event.target.select()
}

const onOpeningInputBlur = () => {
  cefTyping.onBlur()
}
const offerDisabled = computed(() => {
  if (acceptancePending.value || state.value.negotiationStatus === 'thinking' || state.value.negotiationStatus === 'typing' || state.value.negotiationStatus === 'accepted' || state.value.negotiationStatus === 'failed') {
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
  if (state.value.purchaseFailureReason) return false
  return state.value.negotiationStatus === 'failed' && (state.value.amISelling || state.value.playerStartsNegotiation)
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

const resolvedIconType = computed(() => {
  if (state.value.purchaseFailureReason) return 'danger'
  if (state.value.negotiationStatus === 'accepted') return 'checkmark'
  return 'abandon'
})

const resolvedStatusText = computed(() => {
  if (state.value.purchaseFailureReason) {
    return state.value.purchaseFailureReason
  }
  if (state.value.negotiationStatus === 'failed') {
    if (state.value.amISelling) {
      return 'The other party ran out of patience and does not want to buy this vehicle.'
    } else if (state.value.playerStartsNegotiation) {
      return 'The seller ran out of patience and walked away. No deal.'
    } else {
      return 'The other party ran out of patience. You can still buy the vehicle at the starting price: '
    }
  } else if (state.value.negotiationStatus === 'accepted') {
    return 'You negotiated a deal with ' + (state.value.opponentName || opponent.value) + '.'
  }
  return ''
})

const resolvedActionText = computed(() => {
  if (state.value.purchaseFailureReason) {
    return 'Continue'
  }
  if (state.value.negotiationStatus === 'failed') {
    return 'Close'
  }
  if (state.value.amISelling) return 'Continue'
  if (state.value.purchaseAfterAccept) return 'Purchase'
  return 'Go to Purchase Screen'
})

// odometer in metres, shown in the player's length unit
const formatMileage = mileageMeters => formatOdometer(units, mileageMeters)

const negotiationChat = ref(null)

const appendAcceptedHistory = () => {
  if (!Array.isArray(state.value.offerHistory)) state.value.offerHistory = []
  const last = state.value.offerHistory[state.value.offerHistory.length - 1]
  if (last?.negotiationStatus === 'accepted' && Number(last.myOffer) === Number(state.value.theirOffer)) return
  state.value.offerHistory.push({
    myOffer: state.value.theirOffer,
    negotiationStatus: 'accepted'
  })
}

const markSaleAccepted = () => {
  acceptancePending.value = false
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  state.value.purchaseFailureReason = null
  state.value.iAccepted = true
  offerPreview.value = state.value.theirOffer ?? offerPreview.value
  appendAcceptedHistory()
}

const applyPurchaseFailure = (result) => {
  acceptancePending.value = false
  const reason = result?.reason || 'Purchase could not be completed.'
  state.value.purchaseFailureReason = reason
  // Keep deal accepted; purchase failure is separate from negotiation failure.
  state.value.negotiationStatus = 'accepted'
  state.value.status = 'accepted'
  state.value.iAccepted = false
  offerPreview.value = state.value.theirOffer ?? offerPreview.value
}

const refresh = async (payload) => {
  const s = payload || await lua.overhaul_career_market_marketplace.getNegotiationState()
  if (!s) {
    lua.overhaul_career_career.closeAllMenus()
    return
  }
  const priorHistory = state.value.offerHistory
  state.value = {
    ...state.value,
    ...s,
    purchaseFailureReason: s.purchaseFailureReason ?? state.value.purchaseFailureReason ?? null
  }

  if (s.saleCompleted) {
    markSaleAccepted()
  } else if (state.value.purchaseFailureReason) {
    acceptancePending.value = false
    // The price agreement still succeeded; show the existing resolved failure screen.
    state.value.negotiationStatus = 'accepted'
    state.value.status = 'accepted'
    state.value.iAccepted = false
  }
  if (!s.offerHistory && priorHistory?.length) {
    state.value.offerHistory = priorHistory
  }
  const base = state.value.myOffer != null ? state.value.myOffer : state.value.startingPrice
  if (!awaitingOpeningOffer.value && !Number.isNaN(Number(base))) offerPreview.value = Number(base)
  if (awaitingOpeningOffer.value) {
    if (!openingOfferTouched.value && openingOffer.value == null) {
      openingOffer.value = 0
      openingOfferText.value = "0"
    }
    offerPreview.value = Number(openingOffer.value) || 0
  }

  if (state.value.negotiationStatus === 'failed' && !state.value.purchaseFailureReason) {
    offerPreview.value = state.value.startingPrice
  }
}

const submitOffer = async () => {
  if (acceptancePending.value) return
  const price = Number(offerPreview.value)
  if (!Number.isFinite(price)) return
  await lua.overhaul_career_market_marketplace.makeNegotiationOffer(price)
}

const submitOpeningOffer = async () => {
  if (acceptancePending.value) return
  const price = Number(openingOffer.value)
  if (!Number.isFinite(price) || price <= 0) return
  offerPreview.value = price
  openingOfferTouched.value = true
  await lua.overhaul_career_market_marketplace.makeNegotiationOffer(price)
}

const takeOffer = async () => {
  if (acceptancePending.value) return
  acceptancePending.value = true

  let result
  try {
    result = await lua.overhaul_career_market_marketplace.takeTheirOffer()
  } catch (error) {
    acceptancePending.value = false
    throw error
  }

  if (result?.ok === false || result?.ok === 0) {
    applyPurchaseFailure(result)
    return
  }
  // Lua will emit negotiationData with saleCompleted or purchaseFailureReason after
  // the spawned vehicle's live part-condition sync finishes.
  if (result?.pending) return

  if (!result?.ok && state.value.purchaseAfterAccept) {
    await refresh()
    if (state.value.purchaseFailureReason) {
      return
    }
  }

  markSaleAccepted()
}

const cancel = async () => {
  if(state.value.negotiationStatus !== 'accepted')
    await lua.overhaul_career_market_marketplace.cancelNegotiation()
}

const isNegotiationRoute = name => name === "overhaul.computer.vehicleShopping.negotiation" ||
  name === "overhaul.computer.vehicleShopping.vehicles.vehiclePurchase.negotiation"

const returnToOrigin = async () => {
  const routeName = typeof state.value.returnRoute === "string" && state.value.returnRoute && !isNegotiationRoute(state.value.returnRoute)
    ? state.value.returnRoute
    : "play"
  const params = state.value.returnParams && typeof state.value.returnParams === "object"
    ? state.value.returnParams
    : {}
  await lua.extensions.ui_router.navigate(routeName, params)
}

const closeNegotiation = async (event) => {
  if (acceptancePending.value) return
  if (state.value.purchaseFailureReason) {
    await lua.overhaul_career_market_marketplace.dismissNegotiation()
  } else if (state.value.negotiationStatus === 'accepted' && state.value.purchaseAfterAccept && !state.value.iAccepted) {
    await lua.overhaul_career_market_marketplace.dismissNegotiation()
  } else {
    await cancel()
  }
  await returnToOrigin()
  if (event?.stopPropagation) event.stopPropagation()
}

const goBack = async (event) => {
  if (acceptancePending.value) return
  if (state.value.purchaseFailureReason) {
    await lua.overhaul_career_market_marketplace.dismissNegotiation()
    await returnToOrigin()
    if (event?.stopPropagation) event.stopPropagation()
    return
  }

  if (state.value.negotiationStatus === 'accepted' && !state.value.iAccepted) {
    await takeOffer()
    if (acceptancePending.value || state.value.purchaseFailureReason || !state.value.iAccepted) return
  }

  if (state.value.purchaseFailureReason) {
    await lua.overhaul_career_market_marketplace.dismissNegotiation()
  } else {
    await cancel()
  }
  if (state.value.purchaseAfterAccept && state.value.negotiationStatus === 'accepted') {
    await lua.overhaul_career_career.closeAllMenus()
  } else {
    await returnToOrigin()
  }
  if (event?.stopPropagation) event.stopPropagation()
}

const start = async () => {
  await refresh()
  nextTick(() => chatWindow.value?.scrollChatToBottom())
}

const kill = async () => {
  cefTyping.onBlur()
  events.off("negotiationData")
}

const resolvedTone = computed(() => {
  if (state.value.purchaseFailureReason) return "bad"
  return state.value.negotiationStatus === "accepted" ? "ok" : "bad"
})
const resolvedTitle = computed(() => {
  if (state.value.purchaseFailureReason) return "Purchase failed"
  if (state.value.negotiationStatus === "accepted") return "Deal at"
  return "No deal"
})
const showStartingPriceHint = computed(() =>
  state.value.negotiationStatus === "failed" && !state.value.purchaseFailureReason && !state.value.amISelling && !state.value.playerStartsNegotiation)

// ---- shared chat window ----------------------------------------------------------------------
const chatWindow = ref(null)
const vehicleMeta = computed(() => [{ icon: icons.odometer, text: formatMileage(state.value.vehicleMileage) }])
const onSend = (price, { opening } = {}) => {
  if (opening) {
    openingOfferTouched.value = true
    openingOffer.value = price
    openingOfferText.value = String(price)
    offerPreview.value = price
    return submitOpeningOffer()
  }
  offerPreview.value = price
  return submitOffer()
}

// Lua events
events.on("negotiationData", data => {
  refresh(data)
})


onMounted(start)
onUnmounted(kill)

// Wait for negotiation data and let the chat scope own activation.
useRouteReady({
  async waitUntilReady() {
    if (!state.value.active) {
      await new Promise(resolve => {
        const stop = watch(() => state.value.active, active => {
          if (!active) return
          stop()
          resolve()
        })
        setTimeout(() => { stop(); resolve() }, 1500)
      })
    }
    await nextTick()
  },
  onReady() {},
})
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
