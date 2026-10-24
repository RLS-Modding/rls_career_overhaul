<!-- Phone marketplace negotiation: the shared negotiation chat (NegotiationChatWindow) in its compact
     layout inside the phone. Same composable, Lua calls and exits as before. -->
<template>
  <div class="phone-negotiate">
    <NegotiationChatWindow
      compact
      :show-close="false"
      :opponent-name="opponentName"
      :subject-name="state.vehicleNiceName || 'Vehicle'"
      :thumbnail="state.vehicleThumbnail"
      :fallback-icon="icons.car"
      :meta="vehicleMeta"
      :market-value="marketValue != null ? Number(marketValue) || 0 : null"
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
      :resolved-text="resolvedStatusText"
      :resolved-tone="resolvedTone"
      :resolved-action="resolvedActionText"
      @send="onSend"
      @accept="takeOffer"
      @walk-away="exitNegotiation"
      @resolve="goBack" />
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { icons } from '@/common/components/base'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import NegotiationChatWindow from '../../components/negotiation/NegotiationChatWindow.vue'
import { lua } from '@/bridge'
import { usePhoneMarketplaceUi } from '../../composables/usePhoneMarketplaceUi'
import { requestSellTab } from '../../composables/usePhoneMarketplaceListings'
import { useVehicleNegotiation } from '../../composables/useVehicleNegotiation'

usePhoneMarketplaceUi()

/** Selling ends up back in the offers inbox; buying returns to the browse feed. */
const exitToMarketplace = finalState => {
  if (finalState?.amISelling) {
    requestSellTab('offers')
    lua.extensions.ui_router.navigate('phone-marketplace-sell')
    return
  }
  lua.extensions.ui_router.navigate('phone-marketplace')
}

const {
  state,
  opponent,
  acceptancePending,
  offerPreview,
  awaitingOpeningOffer,
  marketValue,
  resolvedTitle,
  resolvedStatusText,
  resolvedActionText,
  formatMileage,
  onOpeningOfferInput,
  submitOffer,
  submitOpeningOffer,
  takeOffer,
  exitNegotiation,
  goBack,
} = useVehicleNegotiation(exitToMarketplace)

const opponentName = computed(() => state.value.opponentName || opponent.value)
const vehicleMeta = computed(() =>
  state.value.vehicleMileage != null ? [{ icon: icons.odometer, text: formatMileage(state.value.vehicleMileage) }] : [])
const resolvedTone = computed(() =>
  state.value.purchaseFailureReason || state.value.negotiationStatus !== 'accepted' ? 'bad' : 'ok')

const onSend = (price, { opening } = {}) => {
  if (opening) {
    onOpeningOfferInput({ target: { value: String(price) } })
    return submitOpeningOffer()
  }
  offerPreview.value = price
  return submitOffer()
}

const handleBack = () => {
  exitNegotiation()
  return true
}
usePhoneScreen({ onBack: handleBack })
</script>

<style scoped lang="scss">
.phone-negotiate {
  // header starts below the phone status bar (same 42px the old phone header used)
  --nego-head-top: 42px;
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  color: #fff;
}
</style>
