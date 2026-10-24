<template>
  <ComputerWrapper title="Property Offers" back @back="goBack">
    <!-- Controller: the panel is the screen's nav scope, active on entry (focus on the first offer's
         first action) so the d-pad works at once; B goes back. -->
    <div ref="offersPanel" class="offers-panel" v-bng-scoped-nav="offersScope">
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
                <span class="price-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(property.askingPrice) }}</span>
              </div>
              <div class="price-divider"></div>
              <div class="price-item">
                <span class="price-label">Market Value</span>
                <span class="price-value dim"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(property.marketValue) }}</span>
              </div>
              <template v-if="mortgageBalance > 0">
                <div class="price-divider"></div>
                <div class="price-item">
                  <span class="price-label">Mortgage Balance</span>
                  <span class="price-value mortgage"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(mortgageBalance) }}</span>
                </div>
              </template>
            </div>
          </div>
        </div>

        <!-- Loading (first load only: a refresh keeps the list mounted so controller focus survives) -->
        <div v-if="loading && !loaded" class="loading-state">
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
        <div v-else class="offers-list" v-bng-ui-nav-scroll>
          <div class="offers-heading">
            <span class="offers-count">{{ offers.length }} {{ offers.length === 1 ? 'Offer' : 'Offers' }}</span>
          </div>

          <div
            v-for="offer in offers"
            :key="offer.index"
            class="offer-card"
            :class="{ underwater: isUnderwater(offer) }"
          >
            <div class="offer-main">
              <div class="offer-buyer">
                <div class="buyer-avatar">{{ offer.buyerName.charAt(0) }}</div>
                <div class="buyer-info">
                  <span class="buyer-name">{{ offer.buyerName }}</span>
                  <span class="offer-time">{{ formatTimeSince(offer.timestamp) }}</span>
                </div>
              </div>
              <div class="offer-price-block" :class="offerColorClass(offerPrice(offer))">
                <div class="offer-price-row">
                  <span class="offer-price-label">Offer</span>
                  <span class="offer-price-value">
                    <template v-if="offer.negotiatedPrice">
                      <span class="original-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(offer.value) }}</span>
                      <span class="negotiated-price"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(offer.negotiatedPrice) }}</span>
                    </template>
                    <template v-else>
                      <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(offer.value) }}
                    </template>
                  </span>
                </div>
                <div class="offer-diff-pill" :class="offerColorClass(offerPrice(offer))">
                  {{ offerDiffText(offerPrice(offer)) }}
                </div>
              </div>
            </div>

            <div class="offer-underwater" v-if="isUnderwater(offer)">
              <div class="underwater-title">Cannot sell — offer below mortgage</div>
              <div class="underwater-figures">
                <div class="underwater-fig">
                  <span class="underwater-fig-label">Offer</span>
                  <span class="underwater-fig-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(offerPrice(offer)) }}</span>
                </div>
                <div class="underwater-fig">
                  <span class="underwater-fig-label">Mortgage due</span>
                  <span class="underwater-fig-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(mortgageBalance) }}</span>
                </div>
                <div class="underwater-fig short">
                  <span class="underwater-fig-label">Short by</span>
                  <span class="underwater-fig-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(mortgageBalance - offerPrice(offer)) }}</span>
                </div>
              </div>
            </div>

            <!-- house buttons: the controller ring, and a disabled one is skipped by the d-pad -->
            <div class="offer-actions">
              <HouseButton
                v-if="!isUnderwater(offer)"
                :data-fk="`accept-${offer.index}`"
                class="act act-main"
                variant="primary"
                :disabled="busy"
                @click="acceptOffer(offer)"
              >
                Accept
              </HouseButton>
              <HouseButton
                v-else
                class="act act-main blocked"
                disabled
              >
                Blocked by mortgage
              </HouseButton>
              <HouseButton :data-fk="`negotiate-${offer.index}`" class="act" :disabled="busy || !offer.negotiationPossible" @click="negotiateOffer(offer)">
                Negotiate
              </HouseButton>
              <HouseButton :data-fk="`decline-${offer.index}`" class="act" variant="quiet-danger" :aria-disabled="offerFocus.busy.value || busy" @click="declineOffer(offer)">
                Decline
              </HouseButton>
            </div>
          </div>
        </div>

    </div>
  </ComputerWrapper>
</template>

<script setup>
import { useActionFocus } from '../composables/useActionFocus'
import { reportUiFailure } from "../utils/safeLua"

import { ref, onMounted, onUnmounted } from 'vue'
import { lua, useBridge } from '@/bridge'
import { useEvents } from '@/services/events'
import { useRoute } from 'vue-router'
import { moneyText } from '../utils/units'
import { moneyMessage } from '../components/moneyMessage'
import ComputerWrapper from './ComputerWrapper.vue'
import { BngIcon, icons } from '@/common/components/base'
import { vBngScopedNav, vBngUiNavScroll } from '@/common/directives'
import { HouseButton, openHouseConfirmation } from '../components/house/index.js'

const route = useRoute()
const { units } = useBridge()
const events = useEvents()
const garageId = route.params.garageId

const property = ref(null)
const offers = ref([])
const loading = ref(true)
const loaded = ref(false)
const offersPanel = ref(null)
const offerFocus = useActionFocus(offersPanel)
const busy = ref(false)
const mortgageBalance = ref(0)

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

const offerPrice = (offer) => offer.negotiatedPrice || offer.value

const isUnderwater = (offer) => {
  return mortgageBalance.value > 0 && offerPrice(offer) < mortgageBalance.value
}

const offerColorClass = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  if (!asking) return ''
  const ratio = value / asking
  if (ratio >= 0.95) return 'offer-green'
  if (ratio >= 0.80) return 'offer-yellow'
  return 'offer-red'
}

const offerDiffText = (value) => {
  if (!property.value) return ''
  const asking = property.value.askingPrice
  if (!asking) return ''
  const diff = value - asking
  const pct = Math.round((diff / asking) * 100)
  if (pct === 0) return 'at asking'
  return (pct > 0 ? '+' : '') + pct + '% vs asking'
}

const loadOffers = async () => {
  loading.value = true
  try {
    const data = await lua.overhaul_career_garage_garageManager.getGarageOffersData(garageId)
    if (data) {
      property.value = data
      offers.value = data.offers || []
    }
  } catch (e) { reportUiFailure(e, "load offers (GarageOffers)") }
  loading.value = false
  loaded.value = true
  try {
    const mortgageInfo = await lua.overhaul_career_garage_property_propertyMortgage.getMortgagePaymentInfo(garageId)
    if (mortgageInfo && mortgageInfo.remainingBalance) {
      mortgageBalance.value = mortgageInfo.remainingBalance
    }
  } catch (e) {
    mortgageBalance.value = 0
  }
}

// Selling is final, so it asks first (one stray A press used to sell the property).
const acceptOffer = async (offer) => {
  if (busy.value) return
  busy.value = true
  try {
    const name = property.value?.name || 'this property'
    const ok = await openHouseConfirmation(
      'Sell property',
      moneyMessage(`Sell ${name} to ${offer.buyerName} for `, moneyText(units, offerPrice(offer)), "? This can't be undone."),
      [
        { label: 'Sell', value: true, extras: { destructive: true } },
        { label: 'Cancel', value: false, extras: { cancel: true } },
      ]
    )
    if (!ok) return
    await lua.overhaul_career_garage_garageManager.acceptOffer(garageId, offer.index)
    lua.overhaul_career_career.closeAllMenus()
  } finally {
    busy.value = false
  }
}

const declineOffer = offer => {
  if (busy.value) return
  return offerFocus.run(async () => {
    await lua.overhaul_career_garage_garageManager.declineOffer(garageId, offer.index)
    await loadOffers()
  })
}

const negotiateOffer = async (offer) => {
  await lua.overhaul_career_garage_property_realEstateNegotiation.startNegotiateSelling(garageId, offer.index)
}

const goBack = () => {
  lua.extensions.ui_router.back()
}

const offersScope = {
  scopeId: 'career-garage-offers',
  activateOnMount: true,
  canDeactivate: () => {
    if (!busy.value) goBack()
    return false
  },
}

onMounted(() => {
  events.on('garageListingsUpdated', loadOffers)
  loadOffers()
})

onUnmounted(() => {
  events.off('garageListingsUpdated', loadOffers)
})
</script>

<style scoped lang="scss">
.offers-panel {
  // scaled unit: the screen keeps the same share of the display at 720p..4K (rem/px-sized it shrank at 1440p),
  // still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  color: white;
  background: #0e0e0e;
  // same width as Garage Listings (the screen it opens from); full-bleed, the offer name and price sat a
  // screen apart at 1440p
  width: min(calc(66 * var(--rls-u, 1rem)), 100%);
  height: 100%;
  max-height: calc(100vh - 120px);
  border-radius: calc(0.875 * var(--rls-u, 1rem));
  overflow: hidden;
  display: flex;
  flex-direction: column;
  padding-bottom: calc(1 * var(--rls-u, 1rem));
  box-sizing: border-box;
}

.property-header {
  overflow: hidden;
  flex-shrink: 0;
}

.header-preview {
  position: relative;
  width: 100%;
  height: calc(10 * var(--rls-u, 1rem));
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
  height: calc(3.75 * var(--rls-u, 1rem));
  background: linear-gradient(to top, #0e0e0e, transparent);
  pointer-events: none;
}

.header-badges {
  position: absolute;
  top: calc(0.625 * var(--rls-u, 1rem));
  left: calc(0.625 * var(--rls-u, 1rem));
}

.tag {
  font-size: calc(0.5625 * var(--rls-u, 1rem));
  font-weight: 700;
  padding: calc(0.1875 * var(--rls-u, 1rem)) calc(0.5 * var(--rls-u, 1rem));
  border-radius: calc(0.25 * var(--rls-u, 1rem));
  letter-spacing: 0.6px;

  &.listed {
    background: rgba(249, 115, 22, 0.85);
    color: white;
  }
}

.header-body {
  padding: calc(1 * var(--rls-u, 1rem)) calc(1.25 * var(--rls-u, 1rem));
}

.header-name {
  font-size: calc(1.25 * var(--rls-u, 1rem));
  font-weight: 700;
  margin: 0 0 calc(0.75 * var(--rls-u, 1rem));
}

.header-prices {
  display: flex;
  align-items: center;
  gap: calc(1 * var(--rls-u, 1rem));
  flex-wrap: wrap;
}

.price-item {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: calc(7.5 * var(--rls-u, 1rem));
}

.price-label {
  font-size: calc(0.5625 * var(--rls-u, 1rem));
  text-transform: uppercase;
  letter-spacing: 1px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.price-value {
  font-size: calc(1.125 * var(--rls-u, 1rem));
  font-weight: 800;
  color: white;
  font-variant-numeric: tabular-nums;

  &.dim {
    color: rgba(255, 255, 255, 0.5);
    font-weight: 600;
    font-size: calc(1 * var(--rls-u, 1rem));
  }

  &.mortgage {
    color: #f87171;
  }
}

.price-divider {
  width: 1px;
  height: calc(2 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.1);
}

.offers-list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0 calc(0.75 * var(--rls-u, 1rem)) calc(1 * var(--rls-u, 1rem)) calc(1.25 * var(--rls-u, 1rem));

  &::-webkit-scrollbar {
    width: calc(0.5 * var(--rls-u, 1rem));
  }
  &::-webkit-scrollbar-track {
    background: rgba(255, 255, 255, 0.05);
    border-radius: calc(0.25 * var(--rls-u, 1rem));
  }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.2);
    border-radius: calc(0.25 * var(--rls-u, 1rem));
  }
  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.3);
  }
}

.offers-heading {
  margin-bottom: calc(0.75 * var(--rls-u, 1rem));
}

.offers-count {
  font-size: calc(0.625 * var(--rls-u, 1rem));
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.offer-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: calc(0.625 * var(--rls-u, 1rem));
  padding: calc(1 * var(--rls-u, 1rem));
  margin-bottom: calc(0.75 * var(--rls-u, 1rem));
  transition: border-color 0.2s;

  &:hover {
    border-color: rgba(255, 255, 255, 0.12);
  }

  &.underwater {
    border-color: rgba(239, 68, 68, 0.25);
  }
}

.offer-main {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: calc(1 * var(--rls-u, 1rem));
  margin-bottom: calc(0.875 * var(--rls-u, 1rem));
}

.offer-buyer {
  display: flex;
  align-items: center;
  gap: calc(0.625 * var(--rls-u, 1rem));
  min-width: 0;
  flex: 1;
}

.buyer-avatar {
  width: calc(2.25 * var(--rls-u, 1rem));
  height: calc(2.25 * var(--rls-u, 1rem));
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.08);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: calc(0.875 * var(--rls-u, 1rem));
  font-weight: 700;
  color: rgba(255, 255, 255, 0.6);
  flex-shrink: 0;
}

.buyer-info {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}

.buyer-name {
  font-size: calc(0.875 * var(--rls-u, 1rem));
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.offer-time {
  font-size: calc(0.6875 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.35);
}

.offer-price-block {
  flex-shrink: 0;
  min-width: calc(10.5 * var(--rls-u, 1rem));
  text-align: right;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: calc(0.375 * var(--rls-u, 1rem));
}

.offer-price-row {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
}

.offer-price-label {
  font-size: calc(0.5625 * var(--rls-u, 1rem));
  text-transform: uppercase;
  letter-spacing: 1px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.35);
}

.offer-price-value {
  font-size: calc(1.375 * var(--rls-u, 1rem));
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  line-height: 1.15;
  letter-spacing: -0.02em;
}

.original-price {
  text-decoration: line-through;
  color: rgba(255, 255, 255, 0.3);
  font-size: calc(0.8125 * var(--rls-u, 1rem));
  font-weight: 600;
  display: block;
}

.negotiated-price {
  display: block;
}

.offer-diff-pill {
  display: inline-flex;
  align-items: center;
  padding: calc(0.1875 * var(--rls-u, 1rem)) calc(0.5625 * var(--rls-u, 1rem));
  border-radius: calc(62.4375 * var(--rls-u, 1rem));
  font-size: calc(0.75 * var(--rls-u, 1rem));
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  background: rgba(255, 255, 255, 0.06);
}

.offer-green {
  color: #4ade80;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #4ade80;
    background: rgba(74, 222, 128, 0.14);
  }
}

.offer-yellow {
  color: #facc15;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #facc15;
    background: rgba(250, 204, 21, 0.14);
  }
}

.offer-red {
  color: #f87171;

  &.offer-diff-pill,
  &.offer-price-block .offer-diff-pill {
    color: #f87171;
    background: rgba(248, 113, 113, 0.14);
  }
}

.offer-underwater {
  padding: calc(0.75 * var(--rls-u, 1rem)) calc(0.875 * var(--rls-u, 1rem));
  background: rgba(239, 68, 68, 0.1);
  border: 1px solid rgba(239, 68, 68, 0.28);
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  margin-bottom: calc(0.75 * var(--rls-u, 1rem));
}

.underwater-title {
  color: #fca5a5;
  font-size: calc(0.8125 * var(--rls-u, 1rem));
  font-weight: 700;
  margin-bottom: calc(0.625 * var(--rls-u, 1rem));
}

.underwater-figures {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: calc(0.625 * var(--rls-u, 1rem));
}

.underwater-fig {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.underwater-fig-label {
  font-size: calc(0.5625 * var(--rls-u, 1rem));
  text-transform: uppercase;
  letter-spacing: 0.8px;
  font-weight: 700;
  color: rgba(252, 165, 165, 0.7);
}

.underwater-fig-value {
  font-size: calc(0.9375 * var(--rls-u, 1rem));
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  color: #fecaca;
  letter-spacing: -0.02em;
}

.underwater-fig.short .underwater-fig-value {
  color: #f87171;
}

.offer-actions {
  display: flex;
  gap: calc(0.5 * var(--rls-u, 1rem));
}

.loading-state, .empty-offers {
  flex-shrink: 0;
  padding: calc(2.5 * var(--rls-u, 1rem)) calc(1.5 * var(--rls-u, 1rem));
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.empty-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: calc(0.75 * var(--rls-u, 1rem));
  padding: calc(2.5 * var(--rls-u, 1rem)) calc(2 * var(--rls-u, 1rem));
  max-width: calc(25 * var(--rls-u, 1rem));
  margin: 0 auto;
}

.empty-icon {
  font-size: calc(2.5 * var(--rls-u, 1rem));
  margin-bottom: calc(0.75 * var(--rls-u, 1rem));
}

.empty-text {
  font-size: calc(1.125 * var(--rls-u, 1rem));
  font-weight: 600;
  color: rgba(255, 255, 255, 0.7);
  margin-bottom: calc(0.5 * var(--rls-u, 1rem));
}

.empty-desc {
  font-size: calc(0.8125 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.35);
  line-height: 1.5;
}

/* action row: house buttons (HouseButton); Accept / Blocked a little wider */
.offer-actions .act {
  flex: 1 1 0;
  min-width: 0;
  font-size: calc(0.75 * var(--rls-u, 1rem));
}
.offer-actions .act-main {
  flex-grow: 1.2;
}
.offer-actions .blocked {
  color: rgba(252, 165, 165, 0.9);
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
