<template>
  <div class="phone-marketplace-sell" v-bng-on-ui-nav:tab_l="() => { tab = 'listings' }" v-bng-on-ui-nav:tab_r="showOffers">
    <div class="tab-bar">

      <button type="button" class="mkt-tab" :class="{ active: tab === 'listings' }" @click="tab = 'listings'">
        Listings <span class="tab-count">{{ listings.length }}</span>
      </button>
      <button type="button" class="mkt-tab" :class="{ active: tab === 'offers' }" @click="showOffers">
        Offers
        <span v-if="unreadCount > 0" class="mkt-badge">{{ unreadCount }}</span>
      </button>
    </div>

    <div class="tab-body">
      <PhoneMarketplaceSellListings
        v-if="tab === 'listings'"
        @see-offers="showOffers"
        @add-listing="openAddSheet"
        @edit-listing="openEditSheet"
      />
      <PhoneMarketplaceOffers v-else />
    </div>

    <PhoneMarketplaceNav active="sell" :unread-count="unreadCount" />

    <PhoneLayer v-if="addSheetOpen" class="sheet-overlay" @click.self="closeAddSheet" label="List a vehicle" @close="closeAddSheet">
      <div class="sheet">
        <div class="sheet-head">
          <h2 class="sheet-title">List a vehicle</h2>
          <button type="button" class="sheet-close" bng-scoped-nav-autofocus @click="closeAddSheet">×</button>
        </div>

        <template v-if="listableVehicles.length">
          <label class="field-label">Vehicle</label>
          <div ref="vehicleMenuRef" class="vehicle-dropdown-wrap">
            <button
              type="button"
              class="vehicle-dropdown-btn"
              :class="{ active: vehicleMenuOpen }"
              :disabled="addInProgress"
              @click.stop="toggleVehicleMenu"
              @mousedown.stop
            >
              <span class="vehicle-dropdown-label">{{ selectedVehicleLabel }}</span>
              <svg
                class="vehicle-dropdown-chevron"
                :class="{ open: vehicleMenuOpen }"
                width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"
              >
                <polyline points="6 9 12 15 18 9" />
              </svg>
            </button>
            <PhoneLayer v-if="vehicleMenuOpen" class="vehicle-dropdown-panel" @click.stop @mousedown.stop label="Choose vehicle" @close="vehicleMenuOpen = false">
              <button
                v-for="vehicle in listableVehicles"
                :key="vehicle.id"
                type="button"
                class="vehicle-dropdown-item"
                :class="{ selected: vehicle.id === selectedVehicleId }"
                @click="selectVehicle(vehicle.id)"
              >
                {{ vehicle.niceName }}
              </button>
            </PhoneLayer>
          </div>

          <div v-if="selectedVehicle && listFormModel" class="phone-list-price">
            <div class="vehicle-meta">
              <div class="name">{{ listFormModel.vehicleName }}</div>
              <div class="meta" v-if="listPriceView.meta">{{ listPriceView.metaPrefix }} <MoneyAmount>{{ listPriceView.marketText }}</MoneyAmount></div>
            </div>

            <div class="price-box">
              <div class="label">Your asking price</div>
              <div class="price"><MoneyAmount>{{ moneyText(listFormModel.price || 0) }}</MoneyAmount></div>
              <div class="step-row">
                <button
                  v-for="step in PRICE_STEPS"
                  :key="step.amount"
                  type="button"
                  class="step-btn"
                  :class="step.size"
                  @click="adjustPrice('list', step.amount)"
                >
                  {{ step.label }}
                </button>
              </div>
              <div v-if="listPriceView.hint.text" class="hint" :class="listPriceView.hint.class">{{ listPriceView.hint.text }}</div>
              <div v-if="listPriceView.offer.text" class="offer-hint" :class="listPriceView.offer.class">{{ listPriceView.offer.text }}</div>
            </div>
          </div>

          <button type="button" class="list-btn" :disabled="!selectedVehicle || addInProgress" @click="listSelectedVehicle">
            List for sale
          </button>
        </template>

        <p v-else-if="inventoryLoaded" class="sheet-empty">
          No eligible vehicles — everything you own may already be listed.
        </p>
      </div>
    </PhoneLayer>

    <PhoneLayer v-if="editListing" class="sheet-overlay" @click.self="closeEditSheet" label="Edit listing" @close="closeEditSheet">
      <div class="sheet">
        <div class="sheet-head">
          <h2 class="sheet-title">Edit asking price</h2>
          <button type="button" class="sheet-close" bng-scoped-nav-autofocus @click="closeEditSheet">×</button>
        </div>
        <div v-if="editFormModel" class="phone-list-price">
          <div class="vehicle-meta">
            <div class="name">{{ editFormModel.vehicleName }}</div>
            <div class="meta" v-if="editPriceView.meta">{{ editPriceView.metaPrefix }} <MoneyAmount>{{ editPriceView.marketText }}</MoneyAmount></div>
          </div>

          <div class="price-box">
            <div class="label">Your asking price</div>
            <div class="price"><MoneyAmount>{{ moneyText(editFormModel.price || 0) }}</MoneyAmount></div>
            <div class="step-row">
              <button
                v-for="step in PRICE_STEPS"
                :key="step.amount"
                type="button"
                class="step-btn"
                :class="step.size"
                @click="adjustPrice('edit', step.amount)"
              >
                {{ step.label }}
              </button>
            </div>
            <div v-if="editPriceView.hint.text" class="hint" :class="editPriceView.hint.class">{{ editPriceView.hint.text }}</div>
            <div v-if="editPriceView.offer.text" class="offer-hint" :class="editPriceView.offer.class">{{ editPriceView.offer.text }}</div>
          </div>
        </div>
        <button type="button" class="list-btn" :disabled="editInProgress" @click="saveEditPrice">
          Save price
        </button>
      </div>
    </PhoneLayer>

    <PhoneLayer v-if="pendingConfirm" class="phone-confirm-overlay" @click.self="cancelConfirm" label="Confirm listing action" @close="cancelConfirm">
      <div class="phone-confirm-modal">
        <p class="confirm-message">{{ pendingConfirm.message }}</p>
        <div class="confirm-actions">
          <button type="button" class="confirm-btn cancel" bng-scoped-nav-autofocus @click.stop="cancelConfirm">Cancel</button>
          <button type="button" class="confirm-btn confirm" @click.stop="handleConfirm">Confirm</button>
        </div>
      </div>
    </PhoneLayer>
  </div>
</template>

<script setup>
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { vBngOnUiNav } from '@/common/directives'
usePhoneScreen()
import PhoneLayer from '../../components/phone/PhoneLayer.vue'
import MoneyAmount from "../../components/MoneyAmount.vue"
import { computed, onBeforeMount, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import PhoneMarketplaceNav from '../../components/phone/PhoneMarketplaceNav.vue'
import PhoneMarketplaceSellListings from '../../components/phone/PhoneMarketplaceSellListings.vue'
import PhoneMarketplaceOffers from '../../components/phone/PhoneMarketplaceOffers.vue'
import { moneyText } from '../../composables/usePhoneMarketplaceFormat'
import { lua, useBridge } from '@/bridge'
import { useVehicleInventoryStore } from '../../stores/vehicleInventoryStore'
import { usePhoneMarketplaceUi } from '../../composables/usePhoneMarketplaceUi'
import { usePhoneMarketplaceListings, takeRequestedSellTab } from '../../composables/usePhoneMarketplaceListings'
import { providePhoneMarketplaceConfirm } from '../../composables/usePhoneMarketplaceConfirm'

usePhoneMarketplaceUi()
const { pendingConfirm, cancelConfirm, runConfirm } = providePhoneMarketplaceConfirm()
const { listings, unreadCount, markOffersSeen, refreshListings } = usePhoneMarketplaceListings({ menuOpen: true })

const tab = ref(takeRequestedSellTab() || 'listings')
const addSheetOpen = ref(false)
const editListing = ref(null)
const listFormModel = ref(null)
const editFormModel = ref(null)
const editInProgress = ref(false)

const PRICE_STEPS = [
  { amount: -5000, label: '-5k', size: 'large' },
  { amount: -500, label: '-500' },
  { amount: -50, label: '-50', size: 'small' },
  { amount: 50, label: '+50', size: 'small' },
  { amount: 500, label: '+500' },
  { amount: 5000, label: '+5k', size: 'large' },
]
const priceFormModels = { list: listFormModel, edit: editFormModel }

function adjustPrice(which, amount) {
  const model = priceFormModels[which]
  const price = Math.max(0, Math.round(((model.value.price || 0) + amount) / 50) * 50)
  model.value = { ...model.value, price }
}

function describePriceForm(model) {
  const marketValue = Number(model?.marketValue || 0)
  const price = Number(model?.price || 0)
  let meta = `Market value: ${moneyText(marketValue)}`
  if (model?.odometerKm) {
    meta = `${new Intl.NumberFormat().format(Math.round(model.odometerKm))} km — Market ${moneyText(marketValue)}`
  }

  let hint = { text: '', class: '' }
  let offer = { text: 'Regular offers expected', class: 'regular' }
  if (marketValue && price) {
    const diff = (price - marketValue) / marketValue
    const percent = Math.round(Math.abs(diff) * 100)
    if (percent < 1) hint = { text: 'Fair market value', class: 'ok' }
    else if (diff > 0) hint = { text: `${percent}% above market`, class: 'high' }
    else hint = { text: `${percent}% below market`, class: 'low' }

    const ratio = price / marketValue
    if (ratio <= 0.90) offer = { text: 'More offers expected', class: 'more' }
    else if (ratio >= 1.20) offer = { text: 'Fewer offers expected', class: 'fewer' }
  }
  const metaPrefix = model?.odometerKm
    ? `${new Intl.NumberFormat().format(Math.round(model.odometerKm))} km — Market`
    : 'Market value:'
  return { meta, metaPrefix, marketText: moneyText(marketValue), hint, offer }
}

const listPriceView = computed(() => describePriceForm(listFormModel.value))
const editPriceView = computed(() => describePriceForm(editFormModel.value))

async function handleConfirm() {
  await runConfirm()
}

// Marking happens once per visit to the tab, and only after listings have actually arrived —
// offers that land while you are already reading keep their unread ring until you come back.
const markSeenOnNextListings = ref(tab.value === 'offers')

function showOffers() {
  tab.value = 'offers'
  markSeenOnNextListings.value = true
}

watch([listings, markSeenOnNextListings], () => {
  if (!markSeenOnNextListings.value || !listings.value.length) return
  markOffersSeen()
  markSeenOnNextListings.value = false
}, { immediate: true })

const vehicleInventoryStore = useVehicleInventoryStore()
const addInProgress = ref(false)
const inventoryLoaded = ref(false)
const selectedVehicleId = ref(null)
const vehicleMenuOpen = ref(false)
const vehicleMenuRef = ref(null)

// ids can arrive as numbers from Lua and strings from the inventory store; compare as strings
const listedIds = computed(() => new Set(listings.value.map(l => String(l.id))))

const listableVehicles = computed(() => {
  const vehicles = vehicleInventoryStore.filteredVehicles || []
  return vehicles.filter(v =>
    v.owned !== false &&
    !v.listedForSale &&
    !listedIds.value.has(String(v.id))
  )
})

const selectedVehicle = computed(() =>
  listableVehicles.value.find(v => v.id === selectedVehicleId.value) || null,
)

const selectedVehicleLabel = computed(() => {
  if (selectedVehicle.value) return selectedVehicle.value.niceName
  if (listableVehicles.value.length) return 'Select a vehicle'
  return 'No vehicles available'
})

watch(listableVehicles, vehicles => {
  if (!vehicles.some(v => v.id === selectedVehicleId.value)) {
    selectedVehicleId.value = vehicles.length ? vehicles[0].id : null
  }
})

watch(selectedVehicle, vehicle => {
  if (!vehicle) {
    listFormModel.value = null
    return
  }
  const marketValue = vehicle.marketSellValue || vehicle.value || 0
  listFormModel.value = {
    vehicleName: vehicle.niceName,
    odometerKm: vehicle.odometer ? vehicle.odometer / 1000 : null,
    marketValue,
    price: Math.max(50, Math.round(marketValue / 50) * 50),
  }
}, { immediate: true })

function openAddSheet() {
  addSheetOpen.value = true
}

function closeAddSheet() {
  addSheetOpen.value = false
  vehicleMenuOpen.value = false
}

function openEditSheet(listingId) {
  const listing = listings.value.find(row => String(row.id) === String(listingId))
  if (!listing) return
  closeAddSheet()
  editListing.value = listing
  const mileage = listing.vehicleData?.mileage
  editFormModel.value = {
    vehicleName: listing.niceName,
    odometerKm: mileage ? mileage / 1000 : null,
    marketValue: listing.marketValue || listing.value || 0,
    price: Math.max(50, Math.round((listing.value || 0) / 50) * 50),
  }
}

function closeEditSheet() {
  editListing.value = null
  editFormModel.value = null
}

async function saveEditPrice() {
  const listing = editListing.value
  const price = Number(editFormModel.value?.price)
  if (editInProgress.value || !listing || !Number.isFinite(price) || price <= 0) return
  editInProgress.value = true
  try {
    const ok = await lua.overhaul_career_market_marketplace.updateListingValue(listing.id, price)
    if (!ok) return
    await refreshListings()
    closeEditSheet()
  } finally {
    editInProgress.value = false
  }
}

function toggleVehicleMenu() {
  if (addInProgress.value || !listableVehicles.value.length) return
  vehicleMenuOpen.value = !vehicleMenuOpen.value
}

function selectVehicle(vehicleId) {
  selectedVehicleId.value = vehicleId
  vehicleMenuOpen.value = false
}

function onDocumentPointerDown(event) {
  if (!vehicleMenuRef.value || vehicleMenuRef.value.contains(event.target)) return
  vehicleMenuOpen.value = false
}

async function listSelectedVehicle() {
  const vehicle = selectedVehicle.value
  if (addInProgress.value || !vehicle || !listFormModel.value) return
  const price = Number(listFormModel.value.price)
  if (!Number.isFinite(price) || price <= 0) return

  addInProgress.value = true
  try {
    await refreshListings()
    if (!listableVehicles.value.some(v => String(v.id) === String(vehicle.id))) return

    const { events } = useBridge()
    const listedOk = await new Promise(resolve => {
      let settled = false
      const requestId = `list_${Date.now()}_${Math.random().toString(16).slice(2)}`
      const finish = ok => {
        if (settled) return
        settled = true
        events.off('marketplaceListVehiclesFinished', onFinished)
        resolve(!!ok)
      }
      const onFinished = payload => {
        if (!payload || payload.requestId !== requestId) return
        finish(payload.ok)
      }
      events.on('marketplaceListVehiclesFinished', onFinished)
      lua.overhaul_career_market_marketplace.listVehicles([{ inventoryId: vehicle.id, value: price }], requestId)
        .catch(() => finish(false))
      // Safety: don't hang the sheet if the finished event never arrives.
      setTimeout(() => finish(false), 8000)
    })

    await refreshListings()
    if (!listedOk) return
    closeAddSheet()
    tab.value = 'listings'
  } finally {
    addInProgress.value = false
  }
}

onBeforeMount(async () => {
  await vehicleInventoryStore.requestInitialData()
  inventoryLoaded.value = true
})

onMounted(() => {
  document.addEventListener('pointerdown', onDocumentPointerDown)
})

onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', onDocumentPointerDown)
})
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.phone-marketplace-sell {
  position: relative;
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  box-sizing: border-box;
  color: #fff;
  overflow: hidden;
}

.tab-bar {
  flex: none;
  display: flex;
  gap: 6px;
  padding: 42px 12px 10px;
}

.tab-count {
  opacity: 0.55;
}

.tab-body {
  @include mkt-scrollbar;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0 12px 14px;
}

.sheet-overlay {
  position: absolute;
  inset: 0;
  z-index: 60;
  display: flex;
  align-items: flex-end;
  background: rgba(0, 0, 0, 0.6);
}

.sheet {
  @include mkt-scrollbar;
  width: 100%;
  max-height: 82%;
  overflow-y: auto;
  padding: 14px 14px 18px;
  box-sizing: border-box;
  border-radius: 18px 18px 0 0;
  background: #171c25;
  border-top: 1px solid rgba(255, 255, 255, 0.12);
}

.sheet-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.sheet-title {
  margin: 0;
  font-size: 15px;
  font-weight: 700;
}

.sheet-close {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.04);
  color: rgba(255, 255, 255, 0.6);
  font: inherit;
  font-size: 16px;
  line-height: 1;
  cursor: pointer;
}

.sheet-empty {
  margin: 0;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.65);
}

.field-label {
  display: block;
  margin-bottom: 6px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
}

.vehicle-dropdown-wrap {
  position: relative;
  min-width: 0;
  margin-bottom: 12px;
}

.vehicle-dropdown-btn {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-width: 0;
  padding: 12px 14px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.05);
  color: #f6f3ee;
  font: inherit;
  font-size: 13px;
  font-weight: 600;
  text-align: left;
  cursor: pointer;

  &.active,
  &:not(:disabled):hover {
    border-color: rgba(126, 182, 255, 0.35);
    background: rgba(255, 255, 255, 0.08);
  }

  &:disabled {
    opacity: 0.5;
    cursor: wait;
  }
}

.vehicle-dropdown-label {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.vehicle-dropdown-chevron {
  flex: 0 0 auto;
  transition: transform 0.15s ease;

  &.open {
    transform: rotate(180deg);
  }
}

.vehicle-dropdown-panel {
  @include mkt-scrollbar;
  position: absolute;
  top: 100%;
  left: 0;
  right: 0;
  z-index: 110;
  margin-top: 6px;
  padding: 8px;
  max-height: 200px;
  overflow-y: auto;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: #171c25;
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.3);
}

.vehicle-dropdown-item {
  display: block;
  width: 100%;
  padding: 10px 12px;
  border: none;
  border-radius: 10px;
  background: transparent;
  color: rgba(228, 233, 242, 0.82);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  text-align: left;
  cursor: pointer;

  &.selected {
    background: rgba(126, 182, 255, 0.18);
    color: #fff;
  }

  &:not(.selected):hover {
    background: rgba(255, 255, 255, 0.05);
  }
}

.list-btn {
  width: 100%;
  margin-top: 12px;
  padding: 12px 14px;
  border: none;
  border-radius: 12px;
  background: #7eb6ff;
  color: #0f1116;
  font: inherit;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.phone-confirm-overlay {
  position: absolute;
  inset: 0;
  z-index: 70;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: rgba(0, 0, 0, 0.65);
}

.phone-confirm-modal {
  width: 100%;
  max-width: 280px;
  padding: 16px;
  border-radius: 16px;
  background: #1a1f28;
  border: 1px solid rgba(255, 255, 255, 0.12);
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45);
}

.confirm-message {
  margin: 0 0 14px;
  font-size: 13px;
  line-height: 1.45;
  color: rgba(255, 255, 255, 0.88);
}

.confirm-actions {
  display: flex;
  gap: 8px;
}

.confirm-btn {
  flex: 1;
  padding: 10px 12px;
  border: none;
  border-radius: 10px;
  font: inherit;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;

  &.cancel {
    background: rgba(255, 255, 255, 0.1);
    color: #fff;
  }

  &.confirm {
    background: #7eb6ff;
    color: #0f1116;
  }
}

.phone-list-price {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.vehicle-meta {
  .name {
    font-size: 14px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .meta {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.6);
  }
}

.price-box {
  padding: 12px;
  border-radius: 12px;
  background: rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(255, 255, 255, 0.08);
  text-align: center;

  .label {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.55);
    margin-bottom: 6px;
  }

  .price {
    font-size: 26px;
    font-weight: 800;
    margin-bottom: 10px;
  }

  .step-row {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 6px;
    margin-bottom: 8px;
  }

  .step-btn {
    padding: 8px 10px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.06);
    color: #f6f3ee;
    font: inherit;
    font-size: 11px;
    font-weight: 700;
    cursor: pointer;

    &.small {
      min-width: 44px;
    }

    &.large {
      min-width: 48px;
    }

    &:active {
      background: rgba(126, 182, 255, 0.2);
    }
  }

  .hint {
    font-size: 11px;
    margin-top: 4px;
    &.ok { color: #29c15a; }
    &.low { color: #7fb6ff; }
    &.high { color: #ffad66; }
  }

  .offer-hint {
    font-size: 10px;
    opacity: 0.8;
    margin-top: 2px;
    &.more { color: #29c15a; }
    &.regular { color: #7fb6ff; }
    &.fewer { color: #ffad66; }
  }
}
</style>
