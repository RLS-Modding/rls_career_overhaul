<!-- Car meet / bazaar offers on the car you brought: one centred near-black card. Header is the car
     (photo first, name, mileage, est. market and asking price), then the asking-price editor, then one
     row per buyer offer with neutral Accept / Negotiate and a quiet Decline. Negotiate hands off to the
     vehicle negotiation chat (career.negotiation) exactly as before. -->
<template>
  <!-- no scope on this screen: B / Start close it directly -->
  <div class="car-meet-offers" v-bng-on-ui-nav:back,menu="onNavClose">
    <div class="rls-house meet-card">
      <header class="meet-head">
        <div v-if="saleData" class="car-photo">
          <img
            v-if="saleData.listing?.thumbnail && !thumbBroken"
            :src="saleData.listing.thumbnail"
            alt=""
            @error="thumbBroken = true" />
          <BngIcon v-else class="car-fallback" :type="icons.car" />
        </div>
        <div class="car-copy">
          <span class="caption">{{ saleData?.guaranteed ? "Car Bazaar" : "Car Meet" }}</span>
          <h1 class="car-name">{{ saleData ? saleData.listing?.niceName || "Brought vehicle" : "Offers on Your Car" }}</h1>
          <div v-if="saleData" class="car-facts">
            <span v-if="mileageText" class="car-fact">
              <span class="fact-key">Mileage</span>
              <span class="fact-val">{{ mileageText }}</span>
            </span>
            <span class="car-fact">
              <span class="fact-key">Est. Market</span>
              <span class="fact-val amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(marketValue) }}</span>
            </span>
            <span class="car-fact">
              <span class="fact-key">Asking</span>
              <span class="fact-val amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(askingPrice) }}</span>
            </span>
          </div>
        </div>
        <HouseButton
          class="close"
          variant="quiet"
          compact
          :icon="icons.xmark"
          binding="back"
          aria-label="Close"
          @click="close" />
      </header>

      <div v-if="!saleData" class="empty">
        <p>No active car meet offers.</p>
      </div>

      <div v-else class="meet-body scroll" v-bng-ui-nav-scroll>
        <p class="status-line" :class="{ sold: saleData.sold }">
          <template v-if="saleData.sold">Sold</template>
          <template v-else-if="saleData.needsVehicleAtMeet">Park your vehicle at the meet to start receiving offers.</template>
          <template v-else-if="saleData.guaranteed">
            {{ saleData.guaranteedGenerated || 0 }}/{{ saleData.guaranteedTarget || 0 }} guaranteed offers generated
          </template>
          <template v-else>Meet buyers can make offers while the event is active.</template>
        </p>

        <!-- asking price -->
        <section class="block">
          <div class="block-head">
            <span class="caption">Asking price</span>
            <span class="range">
              <span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(minAskingPrice) }}</span>
              to
              <span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(maxAskingPrice) }}</span>
            </span>
          </div>
          <div class="price-row">
            <label class="price-field" data-focus-field>
              <BngIcon class="currency" :type="icons.beamCurrency" />
              <input
                v-model.number="askingInput"
                type="number"
                aria-label="Asking price"
                :min="minAskingPrice"
                :max="maxAskingPrice"
                step="50"
                v-bng-text-input
                />
            </label>
            <HouseButton @click="applyAskingPrice">Set Price</HouseButton>
          </div>
          <div class="chips">
            <button
              v-for="q in quickPrices"
              :key="q.label"
              type="button"
              bng-nav-item
              :class="{ active: askingPrice === quickValue(q.multiplier) }"
              @click="setQuickPrice(q.multiplier)">
              {{ q.label }}
            </button>
          </div>
        </section>

        <!-- offers -->
        <section class="block">
          <div class="block-head">
            <span class="caption">Offers</span>
            <span v-if="offers.length" class="count">{{ offers.length }}</span>
          </div>

          <div v-if="offers.length" class="offer-list">
            <article
              v-for="(offer, index) in offers"
              :key="index"
              class="offer-row"
              :class="{ expired: isExpired(offer) }">
              <div class="offer-copy">
                <strong class="buyer">{{ offer.buyerPersonality?.name || "Meet Buyer" }}</strong>
                <span class="offer-amt amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(offer.value) }}</span>
                <span class="offer-meta">
                  <span v-if="isExpired(offer)" class="pill">Expired</span>
                  <template v-else>
                    <template v-if="compare(offer.value).notable">
                      <span class="cmp">{{ compare(offer.value).askText }}</span>
                      <span class="pill" :class="compare(offer.value).marketPct > 0 ? 'ok' : 'bad'">
                        {{ compare(offer.value).marketText }}
                      </span>
                    </template>
                    <span v-else class="cmp">{{ offerComparison(offer.value) }}</span>
                    <span v-if="!offer.negotiationPossible" class="pill">Firm offer</span>
                  </template>
                </span>
              </div>
              <div class="offer-actions">
                <HouseButton variant="quiet" compact @click="declineOffer(index)">
                  {{ isExpired(offer) ? "Discard" : "Decline" }}
                </HouseButton>
                <HouseButton
                  v-if="!isExpired(offer)"
                  compact
                  :disabled="!offer.negotiationPossible"
                  @click="negotiateOffer(index)">
                  Negotiate
                </HouseButton>
                <HouseButton
                  v-if="!isExpired(offer)"
                  compact
                  binding="ok"
                  :disabled="offer.disabled"
                  v-bng-tooltip="'Hold to accept'"
                  v-bng-on-ui-nav:ok.asMouse.focusRequired
                  v-bng-click="{ holdCallback: () => acceptOffer(index), holdDelay: 1000, repeatInterval: 0 }">
                  Accept
                </HouseButton>
              </div>
            </article>
          </div>

          <div v-else class="empty">
            <p>No offers right now. Check back at your car when buyers show interest.</p>
          </div>
        </section>
      </div>
    </div>
  </div>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { computed, onMounted, onUnmounted, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { vBngClick, vBngOnUiNav, vBngTextInput, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { lua, useBridge } from "@/bridge"
import { HouseButton } from "../components/house/index.js"

const { events, units } = useBridge()
const saleData = ref(null)
const asArray = value => {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []
  return Object.values(value)
}
const offers = computed(() => asArray(saleData.value?.offers))
const askingInput = ref(0)
const marketValue = computed(() => Number(saleData.value?.listing?.marketValue || 0))
const askingPrice = computed(() => Number(saleData.value?.listing?.value || marketValue.value || 0))
const minAskingPrice = computed(() => Number(saleData.value?.listing?.minAskingPrice || marketValue.value * 0.5 || 50))
const maxAskingPrice = computed(() => Number(saleData.value?.listing?.maxAskingPrice || marketValue.value * 2 || 50))

// display-only helpers
const wholeMoney = v => Math.round(Number(v) || 0).toLocaleString()
const thumbBroken = ref(false)
watch(() => saleData.value?.listing?.thumbnail, () => (thumbBroken.value = false))
const quickPrices = [
  { label: "Market", multiplier: 1 },
  { label: "+10%", multiplier: 1.1 },
  { label: "+25%", multiplier: 1.25 },
]
const quickValue = multiplier => Math.round((marketValue.value * multiplier) / 50) * 50

// mileage for the header (read-only lookup; the sale payload doesn't carry it)
const mileage = ref(null)
watch(
  () => saleData.value?.inventoryId ?? saleData.value?.listing?.id ?? null,
  async id => {
    mileage.value = null
    if (id == null) return
    try {
      const m = Number(await lua.overhaul_career_market_valueCalculator.getVehicleMileageById(id))
      mileage.value = Number.isFinite(m) && m > 0 ? m : null
    } catch (_) { reportUiFailure(_, "optional action (CarMeetOffers)") }
  },
  { immediate: true }
)
const mileageText = computed(() => (mileage.value ? units.buildString("length", mileage.value, 0) : null))

const refresh = async () => {
  lua.overhaul_career_carmeets_carmeets.requestMeetSaleOfferData()
}

const updateSaleData = data => {
  saleData.value = data || null
}

watch(saleData, data => {
  if (data?.listing) askingInput.value = Math.round(Number(data.listing.value || data.listing.marketValue || 0))
}, { immediate: true })

const updateFromOverview = data => {
  if (!data) return
  const overviewSale = data.sale || data.bazaar
  if (overviewSale) saleData.value = overviewSale
}


const clampAsking = value => Math.max(minAskingPrice.value, Math.min(maxAskingPrice.value, Number(value || marketValue.value || 0)))

const applyAskingPrice = async () => {
  const data = await lua.overhaul_career_carmeets_carmeets.setMeetSaleAskingPrice(clampAsking(askingInput.value))
  if (data) updateSaleData(data)
}

const setQuickPrice = multiplier => {
  askingInput.value = quickValue(multiplier)
  applyAskingPrice()
}

// how an offer compares to the asking price and the market; market gets a coloured pill only when it's
// notably above / below (10%+)
const NOTABLE_PCT = 10
const compare = value => {
  const offer = Number(value || 0)
  const ask = askingPrice.value || 1
  const market = marketValue.value || 1
  const askPct = Math.round(((offer - ask) / ask) * 100)
  const marketPct = Math.round(((offer - market) / market) * 100)
  const askText = askPct === 0 ? "at asking" : `${Math.abs(askPct)}% ${askPct > 0 ? "over" : "under"} asking`
  const marketText = marketPct === 0 ? "at market" : `${Math.abs(marketPct)}% ${marketPct > 0 ? "over" : "under"} market`
  return { askText, marketText, marketPct, notable: Math.abs(marketPct) >= NOTABLE_PCT }
}

const offerComparison = value => {
  const { askText, marketText } = compare(value)
  return `${askText}, ${marketText}`
}

// carmeets.lua marks an offer expired with expiredViewCounter = 0 when the meet ends (nil while live)
const isExpired = offer => offer?.expiredViewCounter != null

const acceptOffer = async index => {
  await lua.overhaul_career_carmeets_carmeets.acceptBazaarOffer(index + 1)
  await refresh()
}

const declineOffer = async index => {
  await lua.overhaul_career_carmeets_carmeets.declineBazaarOffer(index + 1)
  await refresh()
}

const negotiateOffer = async index => {
  await lua.overhaul_career_carmeets_carmeets.negotiateBazaarOffer(index + 1)
}

// B / Start handler for this unscoped screen: the directive's listener does not stop the ui_nav event by
// itself, so without stopPropagation it also reaches the game's global fallback (ui_router.back())
const onNavClose = event => {
  event?.stopPropagation?.()
  close()
}

const close = () => {
  lua.overhaul_career_career.closeAllMenus()
}

// Controller: nothing is focused on entry (no scope), and declining the last offer removes the focused
// row. Entry lands on the first offer, a removed row on the last remaining one (its neighbour), at the
// (hold) Accept, else the first price chip / Close.
const pickOfferFocus = (last = false) => {
  const card = document.querySelector(".car-meet-offers")
  const rows = [...(card?.querySelectorAll(".offer-row") || [])]
  const row = last ? rows[rows.length - 1] : rows[0]
  return row?.querySelector(".offer-actions button:last-child:not([disabled])") ||
    row?.querySelector(".offer-actions button:not([disabled])") ||
    card?.querySelector(".chips button") ||
    card?.querySelector(".close")
}
// entry first (watchers run in order), then removals
watch(saleData, (data, prev) => { if (data && !prev) refocusIfLost(() => pickOfferFocus(false)) }, { flush: "post" })
watch(() => offers.value.length, (n, prev) => { if (prev > 0) refocusIfLost(() => pickOfferFocus(true)) }, { flush: "post" })

onMounted(() => {
  events.on("onCarMeetSaleOfferData", updateSaleData)
  events.on("onCarMeetOverview", updateFromOverview)
  events.on("marketplaceListingsUpdated", refresh)
  refresh()
})

onUnmounted(() => {
  events.off("onCarMeetSaleOfferData", updateSaleData)
  events.off("onCarMeetOverview", updateFromOverview)
  events.off("marketplaceListingsUpdated", refresh)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* full-screen overlay: the card sits centred */
.car-meet-offers {
  width: 100%;
  height: 100%;
  min-height: 100vh; // the route container has no height of its own
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2em;
}

.meet-card {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  width: min(44em, 94vw);
  max-height: 88vh;
  border-radius: var(--radius-control);
  overflow: hidden;
  background: rgba(21, 21, 23, 0.95);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

/* ---- header: the car, photo first */
.meet-head {
  flex: 0 0 auto;
  display: flex;
  align-items: flex-start;
  gap: 1em;
  padding: 1em 0.8em 1em 1em;
  border-bottom: 1px solid var(--line);
}
.car-photo {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 13em;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-tile);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}
.car-fallback {
  font-size: 2.2em;
  color: rgba(255, 255, 255, 0.3);
}
.car-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: grid;
  align-content: start;
  gap: 0.3em;
  padding-top: 0.15em;
}
.car-name {
  margin: 0;
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}
.car-facts {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em 1.6em;
  margin-top: 0.35em;
}
.car-fact {
  display: grid;
  gap: 0.15em;
}
.fact-key {
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--faint);
}
.fact-val {
  font-weight: 700;
  font-size: 1.05em;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.close {
  flex: 0 0 auto;
  margin-top: -0.2em;
}

/* inline money: glyph + number on the text baseline, always gold */
.amt {
  display: inline;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-icon) {
    display: inline-block;
    margin-right: 0.15em;
    font-size: 0.95em;
    line-height: 1;
    vertical-align: -0.08em;
  }
}

/* ---- body */
.meet-body {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 1.2em;
  padding: 0.9em 0.7em 1em 1em;
  overscroll-behavior: contain;
}
.status-line {
  margin: 0;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.35;
  font-variant-numeric: tabular-nums;
  &.sold {
    color: var(--ok-ink);
  }
}
.block {
  display: grid;
  gap: 0.55em;
}
.block-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.25em 1em;
  flex-wrap: wrap;
}
.range,
.count {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  .amt {
    color: var(--faint);
    font-weight: 700;
  }
}

/* asking price editor */
.price-row {
  display: flex;
  align-items: stretch;
  gap: 0.5em;
}
.price-field {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0 0.8em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  &:focus-within {
    box-shadow: var(--focus);
  }
  .currency {
    flex: 0 0 auto;
    color: var(--money);
    font-size: 1.05em;
  }
  input {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    padding: 0.72em 0 0.5em;
    border: 0;
    background: transparent;
    color: var(--money);
    font: inherit;
    font-size: 1.1em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
    line-height: 1;
    -moz-appearance: textfield;
    appearance: textfield;
    &:focus {
      outline: none;
    }
    &::-webkit-inner-spin-button,
    &::-webkit-outer-spin-button {
      appearance: none;
      margin: 0;
    }
  }
}

/* ---- offers: one row per buyer */
.offer-list {
  display: grid;
  gap: 0.4em;
}
.offer-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.6em 1em;
  padding: 0.75em 0.8em 0.7em 0.9em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.expired {
    opacity: 0.6;
  }
}
.offer-copy {
  flex: 1 1 14em;
  min-width: 0;
  display: grid;
  gap: 0.2em;
}
.buyer {
  font-size: 1.15em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.offer-amt {
  font-size: 1.05em;
  line-height: 1.2;
}
.offer-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.3em 0.6em;
  margin-top: 0.1em;
}
.cmp {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  line-height: 1.3;
}
.offer-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.4em;
  margin-left: auto;
}
</style>
