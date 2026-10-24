<!-- RLS "Sell Vehicles" tab, house style. Same listings data, events and Lua calls as before; layout: one panel
     per listing (photo, name, offer count, asking price in gold, est. market value faint, edit / remove), its
     offers as plain lines (buyer, offer in gold, how far off the asking price) with Deny / Negotiate / Accept.
     Orange only when there is exactly one live offer to accept, or for Add Listing on an empty tab. -->
<template>
  <div class="market rls-house" v-bng-blur="1">
    <!-- nothing listed yet -->
    <div v-if="listings.length === 0" class="empty market-empty">
      <BngIcon class="empty-icon" :type="icons.carCoins" />
      <h3>No listings yet</h3>
      <p>List a vehicle from your inventory and buyers will send their offers here.</p>
      <HouseButton variant="primary" :icon="icons.plus" @click="listVehicle">Add Listing</HouseButton>
    </div>

    <template v-else>
      <div class="market-list scroll" v-bng-ui-nav-scroll>
        <article
          v-for="listing in listings"
          :key="listing.id"
          :data-listing-id="listing.id"
          class="listing panel"
          :class="{ 'is-disabled': listing.disabled }">
          <header class="listing-head">
            <div v-if="listing.thumbnail && !brokenThumbs[listing.id]" class="listing-photo">
              <img :src="listing.thumbnail" alt="" @error="brokenThumbs[listing.id] = true" />
            </div>

            <!-- name biggest, offer count beside it, tools under it -->
            <div class="listing-title">
              <div class="listing-name-row">
                <h2 class="listing-name">{{ listing.niceName }}</h2>
                <span class="pill">{{ offerCountText(listing) }}</span>
              </div>
              <div class="listing-tools">
                <HouseButton compact :icon="icons.edit" @click.stop="editListingPrice(listing)">Edit price</HouseButton>
                <HouseButton
                  compact
                  variant="quiet-danger"
                  :icon="icons.trashBin1"
                  :title="$translate.instant('ui.career.partShopping.remove')"
                  @click.stop="confirmRemoveListingScreen(listing.id)" />
              </div>
            </div>

            <div class="listing-price">
              <span class="caption">Asking price</span>
              <strong class="asking"><BngUnit :money="listing.value" /></strong>
              <span class="hint market-value">
                Est. market value
                <span class="amt"><BngIcon :type="icons.beamCurrency" />{{ wholeMoney(listing.marketValue || listing.marketSellValue || listing.value) }}</span>
              </span>
            </div>
          </header>

          <p v-if="listing.disabled" class="notice bad">{{ listing.disableReason }}</p>

          <div class="lines offers">
            <div
              v-for="(offer, index) in listing.offers"
              :key="offer.id ?? index"
              class="line offer"
              :class="{ expired: isExpired(offer), active: offer.active }"
              v-bng-scoped-nav="{ type: 'container' }"
              @mouseover="onOfferHovered(offer)"
              @mouseleave="onOfferUnhovered(offer)"
              @activate="onActivated(offer)"
              @deactivate="onDeactivated(offer)">
              <div class="offer-copy">
                <div class="offer-buyer">
                  <span class="buyer-name">{{ offer.buyerPersonality.name }}</span>
                  <span v-if="isExpired(offer)" class="pill">Expired</span>
                </div>
                <div class="offer-value">
                  <strong class="offer-amount"><BngUnit :money="offer.value" /></strong>
                  <span v-if="deltaOf(listing, offer).low" class="pill bad">{{ deltaOf(listing, offer).text }}</span>
                  <span v-else class="offer-delta">{{ deltaOf(listing, offer).text }}</span>
                </div>
              </div>

              <div class="offer-actions">
                <HouseButton
                  compact
                  :variant="isExpired(offer) ? 'quiet' : 'quiet-danger'"
                  @click="declineOffer(listing, offer, index)">
                  {{ isExpired(offer) ? "Discard" : "Deny" }}
                </HouseButton>
                <HouseButton
                  v-if="!isExpired(offer)"
                  compact
                  :icon="icons.chatBubble"
                  :disabled="!offer.negotiationPossible || offer.value >= listing.value || listing.disabled || listing.damagedAfterListing"
                  @click="startNegotiateBuyingOffer(listing, offer, index)">
                  Negotiate
                </HouseButton>
                <HouseButton
                  v-if="!isExpired(offer)"
                  compact
                  :variant="liveOfferCount === 1 ? 'primary' : 'neutral'"
                  :disabled="listing.disabled || offer.disabled || listing.damagedAfterListing"
                  @click="acceptOffer(listing, offer, index)">
                  Accept Offer
                </HouseButton>
              </div>
            </div>
            <p v-if="Object.keys(listing.offers || {}).length === 0" class="hint no-offers">
              {{ $translate.instant("ui.career.vehicleMarketplace.noOffers") }}
            </p>
          </div>
        </article>
      </div>

      <!-- pinned to the bottom of the card -->
      <footer class="market-foot">
        <HouseButton :icon="icons.plus" @click="listVehicle">Add Listing</HouseButton>
      </footer>
    </template>
  </div>
</template>

<script setup>
import { safeLua } from "../../utils/safeLua.js"

import { ref, reactive, computed, onMounted, onUnmounted } from "vue"

const props = defineProps({
  racingTeamBusinessId: {
    type: String,
    default: "",
  },
})
import { lua, useBridge } from "@/bridge"
import { BngUnit, BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import { useComputerStore } from "../../stores/computerStore"
import { HouseButton, openHouseConfirmation, openHouseAmountPrompt } from "../house/index.js"
import { $translate } from "@/services/translation"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"

const computerStore = useComputerStore()
const { events } = useBridge()

const listings = ref([])
let listingPending = false
let marketplaceAlive = true

// ---- view helpers (display only)
const brokenThumbs = reactive({})
const wholeMoney = v => Math.round(Number(v) || 0).toLocaleString()
const offersOf = listing => {
  const offers = listing?.offers
  if (Array.isArray(offers)) return offers
  return offers && typeof offers === "object" ? Object.values(offers) : []
}
// Lua sets expiredViewCounter to 0 the moment an offer expires; 0 is falsy in JS, so test for presence.
const isExpired = offer => offer?.expiredViewCounter !== undefined && offer?.expiredViewCounter !== null
const liveOfferCount = computed(() =>
  listings.value.reduce((sum, listing) => sum + offersOf(listing).filter(offer => !isExpired(offer)).length, 0)
)
const offerCountText = listing => {
  const n = offersOf(listing).length
  return `${n} ${n === 1 ? "offer" : "offers"}`
}
// how far the offer sits from the asking price; red only when it is well under (15% or more)
const deltaOf = (listing, offer) => {
  const asking = Number(listing?.value) || 0
  const diff = (Number(offer?.value) || 0) - asking
  if (diff === 0) return { text: "Matches asking", low: false }
  const text = `${wholeMoney(Math.abs(diff))} ${diff < 0 ? "under" : "over"} asking`
  return { text, low: diff < 0 && asking > 0 && -diff / asking >= 0.15 }
}

const confirmRemoveListingScreen = async listingId => {
  const res = await openHouseConfirmation("", $translate.instant("ui.career.vehicleMarketplace.confirmRemoveListing"), [
    { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true, destructive: true } },
    { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true } },
  ])

  if (res) {
    removeVehicleListing(listingId)
  }
}

const editListingPrice = async listing => {
  const current = Math.max(50, Math.round((Number(listing.value) || 0) / 50) * 50)
  const res = await openHouseAmountPrompt("Choose a new asking price.", "Edit asking price", {
    defaultValue: current,
    field: { min: 50, step: 50, presets: [current, current * 0.9, current * 1.1], allowText: true },
    confirmLabel: $translate.instant("ui.common.okay"),
    cancelLabel: $translate.instant("ui.common.cancel"),
  })
  if (res === false || res == null) return
  const price = Number(res)
  if (!Number.isFinite(price) || price <= 0) return
  lua.overhaul_career_market_marketplace.updateListingValue(listing.id, price).then(getNewData)
}

const onActivated = (offer) => { offer.active = true }

const onDeactivated = (offer) => { offer.active = false }

const onOfferHovered = (offer) => { offer.hovered = true }

const onOfferUnhovered = (offer) => { offer.hovered = false }

// an empty Lua table arrives as {} (and a keyed one as an object), so store a real array: the empty state
// tests listings.length. Offers are left as sent (their keys/indices must match the Lua side, see below).
const asArray = value => {
  if (Array.isArray(value)) return value
  if (!value || typeof value !== "object") return []
  return Object.values(value)
}
const handleListings = (data) => { listings.value = asArray(data) }

const getNewData = () => lua.overhaul_career_market_marketplace.getListings().then(handleListings)

// getListings() reverses offers and pushes disabled ones to the end, so a row index does not
// match listing.offers on the Lua side. Resolve by stable offer id when one is available.
// Controller: accepting / denying removes the offer line (and the focused button); once the list is
// back, a pad lands on the same listing's next offer, else its tools, else the first usable button
const focusListing = (listingId, offerIndex) => refocusIfLost(() => {
  const root = document.querySelector(".market")
  const panel = [...(root?.querySelectorAll("[data-listing-id]") || [])].find(el => el.dataset.listingId === String(listingId))
  const offers = [...(panel?.querySelectorAll(".line.offer") || [])]
  const offerEl = offers[Math.min(offerIndex, offers.length - 1)]
  return offerEl?.querySelector("button:not([disabled])") ||
    panel?.querySelector("button:not([disabled])") ||
    root?.querySelector("button:not([disabled])")
})

const acceptOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.overhaul_career_market_marketplace.acceptOfferById(offer.id)
    : lua.overhaul_career_market_marketplace.acceptOffer(listing.id, offerIndex + 1)
  call.then(getNewData).then(() => focusListing(listing.id, offerIndex))
}

const declineOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.overhaul_career_market_marketplace.declineOfferById(offer.id)
    : lua.overhaul_career_market_marketplace.declineOffer(listing.id, offerIndex + 1)
  call.then(getNewData).then(() => focusListing(listing.id, offerIndex))
}

const startNegotiateBuyingOffer = (listing, offer, offerIndex) => {
  const call = offer.id != null
    ? lua.overhaul_career_market_marketplace.startNegotiateBuyingOfferById(offer.id, false)
    : lua.overhaul_career_market_marketplace.startNegotiateBuyingOffer(listing.id, offerIndex + 1)
  call.then(getNewData)
}

const removeVehicleListing = (inventoryId) => {
  lua.overhaul_career_market_marketplace.removeVehicleListing(inventoryId).then(getNewData)
}

const listVehicle = async () => {
  if (listingPending) return
  const bid = props.racingTeamBusinessId && String(props.racingTeamBusinessId)
  if (bid) {
    listingPending = true
    try {
      let rows = []
      try {
        rows = await lua.overhaul_career_business_computer.getRtFleetOpts(bid)
      } catch (_err) {
        rows = []
      }
      const arr = Array.isArray(rows) ? rows : Object.values(rows || {})
      if (!arr.length || !marketplaceAlive) return
      const vehicleId = await openHouseConfirmation("List fleet vehicle", "Choose a vehicle to list.", [
        { label: "Cancel", value: false, extras: { cancel: true } },
        ...arr.filter(r => r.vehicleId != null).map(r => ({ label: r.label || String(r.vehicleId), value: r.vehicleId })),
      ])
      if (!marketplaceAlive || vehicleId === false || vehicleId == null) return
      const askRaw = await openHouseAmountPrompt("Choose an asking price.", "List fleet vehicle", {
        defaultValue: 10000,
        field: { min: 50, step: 50, presets: [5000, 10000, 25000, 50000], allowText: true },
      })
      if (!marketplaceAlive || askRaw === false || askRaw == null) return
      const price = Number(askRaw)
      if (!Number.isFinite(price) || price <= 0) return
      await safeLua(() => lua.overhaul_career_market_marketplace.addRtListing(bid, vehicleId, price), "VehicleMarketplace: listVehicle")
      if (marketplaceAlive) getNewData()
    } finally {
      listingPending = false
    }
    return
  }
  lua.overhaul_career_garage_inventory.openInventoryMenuForChoosingListing()
}

const start = () => {
  lua.overhaul_career_market_marketplace.menuOpened(true)
  events.on("marketplaceListingsUpdated", handleListings)
  getNewData()
}

const stop = () => {
  marketplaceAlive = false
  lua.overhaul_career_market_marketplace.menuOpened(false)
  // off(name) on the shared emitter removes every listener.
  events.off("marketplaceListingsUpdated", handleListings)
}

onMounted(start)
onUnmounted(stop)

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* near-black card top-left under the screen heading; em off a resolution-scaled font */
.market.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  width: min(60em, 100%);
  max-height: 100%;
  min-height: 0;
  overflow: hidden;
  color: #fff;
  background: rgba(21, 21, 23, 0.93);
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

/* ---- empty tab */
.market-empty {
  justify-items: start;
  text-align: left;
  padding: 1.4em 1.3em 1.3em;
  p {
    max-width: 30em;
  }
}
.empty-icon {
  font-size: 2.2em;
  color: var(--faint);
}

/* ---- listings */
.market-list {
  flex: 1 1 auto;
  min-height: 0;
  display: grid;
  align-content: start;
  gap: 0.8em;
  padding: 1em 0.5em 1em 1.1em;
}

.listing.panel {
  gap: 0.7em;
  padding: 0.9em 0.95em 0.6em;
}

.listing-head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 0.8em 1em;
}

.listing-photo {
  flex: 0 0 auto;
  width: 11em;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.listing-title {
  flex: 1 1 14em;
  min-width: 0;
  display: grid;
  align-content: start;
  gap: 0.6em;
}
.listing-name-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35em 0.6em;
}
.listing-name {
  margin: 0;
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}
.listing-tools {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em;
}

/* asking price gold second, market value faint */
.listing-price {
  flex: 0 0 auto;
  display: grid;
  justify-items: end;
  gap: 0.15em;
  margin-left: auto;
  text-align: right;
  .caption {
    font-size: 0.68em;
  }
}
.asking {
  color: var(--money);
  --units-icon-color: var(--money);
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-unit),
  :deep(.unit) {
    color: inherit;
  }
}
.market-value {
  font-variant-numeric: tabular-nums;
}

/* money inside a sentence: coin glyph + whole number on the text line */
.amt {
  display: inline;
  margin-left: 0.15em;
  color: var(--money);
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-icon) {
    display: inline-block;
    margin-right: 0.15em;
    font-size: 0.95em;
    line-height: 1;
    vertical-align: -0.1em;
    color: var(--money);
  }
}

.notice {
  margin: 0;
}

/* ---- offers */
.offers {
  border-top: 1px solid var(--line);
}
.line.offer {
  flex-wrap: wrap;
  gap: 0.5em 1em;
  padding: 0.65em 0.35em 0.5em;
  &.active {
    background: rgba(255, 255, 255, 0.04);
  }
}
.offer-copy {
  flex: 1 1 14em;
  min-width: 0;
  display: grid;
  gap: 0.2em;
}
.offer-buyer {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5em;
}
.buyer-name {
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 700;
}
.offer-value {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.3em 0.7em;
}
.offer-amount {
  color: var(--money);
  --units-icon-color: var(--money);
  font-size: 1.25em;
  font-weight: 800;
  line-height: 1.15;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-unit),
  :deep(.unit) {
    color: inherit;
  }
}
.offer-delta {
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.offer-value .pill {
  align-self: center;
  font-variant-numeric: tabular-nums;
}
.offer-actions {
  flex: 0 0 auto;
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.4em;
  margin-left: auto;
}

/* expired: dim the offer, keep Discard readable */
.line.offer.expired .offer-copy {
  opacity: 0.5;
}

.no-offers {
  padding: 0.65em 0.35em 0.4em;
  font-size: 0.88em;
}

/* ---- add listing, pinned to the bottom of the card */
.market-foot {
  flex: 0 0 auto;
  display: flex;
  justify-content: flex-start;
  padding: 0.75em 1.1em 0.85em;
  border-top: 1px solid var(--line);
}
</style>
