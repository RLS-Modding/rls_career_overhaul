<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- RLS Garage Listings computer, house style. Same data, Lua calls and flows as before; layout:
     a portfolio summary, then one photo-first card per property (name, value in gold, capacity and
     vehicles as plain-glyph lines) with its actions. Orange is left to the open listing form's
     List for Sale; status colour only where something is off (an unrealistic asking price). -->
<template>
  <ComputerWrapper title="Garage Listings" back @back="goBack">
    <div class="listings rls-house">
      <!-- Loading -->
      <div v-if="loading" class="state hint">Loading properties</div>

      <!-- Empty State -->
      <div v-else-if="garages.length === 0" class="state empty">
        <BngIcon class="empty-icon" :type="icons.garage01" />
        <h3>No properties yet</h3>
        <p>You don't own any properties yet.</p>
      </div>

      <template v-else>
        <!-- portfolio at a glance (no repeated page title) -->
        <div class="summary">
          <div class="fact">
            <span class="fact-key">Properties</span>
            <span class="fact-value">{{ garages.length }}</span>
          </div>
          <div class="fact">
            <span class="fact-key">Listed</span>
            <span class="fact-value">{{ listedCount }}</span>
          </div>
          <div class="fact">
            <span class="fact-key">Offers</span>
            <span class="fact-value">{{ totalOffers }}</span>
          </div>
          <div class="fact money">
            <span class="fact-key">Market value</span>
            <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(portfolioValue) }}</span>
          </div>
        </div>

        <!-- Garage Cards -->
        <div class="garages scroll" v-bng-ui-nav-scroll>
          <div class="garages-grid">
            <article
              v-for="garage in garages"
              :key="garage.garageId"
              :data-garage-key="garage.garageId"
              class="garage-card"
              :class="{ 'is-listed': garage.isListed, 'is-editing': expandedGarage === garage.garageId }">
              <!-- Preview Image -->
              <div class="card-photo">
                <img v-if="garage.preview" :src="garage.preview" alt="" />
                <BngIcon v-else class="photo-fallback" :type="icons.garage01" />
                <div v-if="hasTags(garage)" class="photo-tags">
                  <span v-if="garage.isListed" class="photo-tag listed">Listed</span>
                  <span v-if="garage.offerCount > 0" class="photo-tag">
                    {{ garage.offerCount }} {{ garage.offerCount === 1 ? "offer" : "offers" }}
                  </span>
                  <span v-if="garage.canReclaim" class="photo-tag">Reclaimable</span>
                  <span v-if="garage.isRented" class="photo-tag">Rented</span>
                  <span v-if="garage.isStarter" class="photo-tag">Starter</span>
                  <span v-else-if="garage.isGranted" class="photo-tag">Granted</span>
                </div>
              </div>

              <!-- Card Body -->
              <div class="card-body">
                <div class="card-head">
                  <div class="card-title">
                    <h2 class="card-name">{{ garage.name }}</h2>
                    <span v-if="garage.neighborhood" class="card-place">
                      <BngIcon class="line-icon" :type="icons.mapPoint" />{{ garage.neighborhood }}
                    </span>
                  </div>
                  <div class="card-value">
                    <span class="caption">{{ garage.isListed ? "Asking" : "Market value" }}</span>
                    <strong class="value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(garage.isListed ? garage.askingPrice : garage.marketValue) }}</strong>
                    <span v-if="garage.isListed" class="hint">Market <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(garage.marketValue) }}</span>
                  </div>
                </div>

                <div class="card-specs">
                  <span class="spec">
                    <BngIcon class="line-icon" :type="icons.car" />
                    {{ garage.vehicleCount }} of {{ garage.capacity }} {{ garage.capacity === 1 ? "space" : "spaces" }} in use
                  </span>
                </div>

                <!-- Reclaim previously granted property -->
                <div v-if="garage.canReclaim" class="card-actions">
                  <HouseButton block :icon="icons.keys1" @click="confirmReclaim(garage)">Reclaim free</HouseButton>
                  <p class="hint">You moved out earlier. Reclaim access at no cost.</p>
                </div>

                <!-- Rented: show status only (cannot list for sale) -->
                <div v-else-if="garage.isRented" class="card-actions">
                  <p class="hint with-icon"><BngIcon class="line-icon" :type="icons.lockClosed" />Rented property, so it can't be listed for sale.</p>
                </div>

                <!-- Listed State: show offers button + remove listing -->
                <div v-else-if="garage.isListed" class="card-actions">
                  <div class="action-row">
                    <HouseButton class="grow" :icon="icons.chatBubble" @click="viewOffers(garage)">
                      {{ garage.offerCount > 0 ? `View offers (${garage.offerCount})` : "View offers" }}
                    </HouseButton>
                    <HouseButton variant="quiet" :icon="icons.trashBin1" @click="removeListing(garage)">Remove listing</HouseButton>
                  </div>
                </div>

                <!-- Granted / unpaid ownership: Move out instead of selling -->
                <div v-else-if="garage.isGranted" class="card-actions">
                  <HouseButton
                    block
                    :icon="icons.exit"
                    :disabled="!garage.canMoveOut"
                    :title="moveOutTitle(garage)"
                    @click="confirmMoveOut(garage)">
                    Move out
                  </HouseButton>
                  <p v-if="!garage.canMoveOut && garage.vehicleCount > 0" class="hint with-icon">
                    <BngIcon class="line-icon" :type="icons.car" />{{ vehiclesLeftText(garage) }}
                  </p>
                  <p v-else class="hint">No refund. You'll give up access to this property.</p>
                </div>

                <!-- Not Listed: show listing form -->
                <div v-else class="card-actions">
                  <!-- Listing Form (expanded) -->
                  <div v-if="expandedGarage === garage.garageId" class="listing-form">
                    <label class="caption" :for="`price-${garage.garageId}`">Asking price</label>
                    <div class="price-field" data-focus-field>
                      <BngIcon class="currency-sign" :type="icons.beamCurrency" />
                      <input
                        :id="`price-${garage.garageId}`"
                        ref="priceInputRef"
                        type="number"
                        class="price-input"
                        v-model.number="listingPrice"
                        v-bng-text-input
                        :placeholder="garage.marketValue"
                        min="1000"
                        @keydown.stop @keyup.stop @keypress.stop
                        @input="updateGuidance(garage)"
                      />
                    </div>
                    <div class="steps">
                      <HouseButton
                        v-for="step in priceSteps"
                        :key="step.amount"
                        compact
                        class="step"
                        @click="adjustPrice(step.amount, garage)">
                        {{ step.label }}
                      </HouseButton>
                    </div>

                    <!-- Price Guidance -->
                    <div v-if="priceGuidance" class="guidance" :class="guidanceClass">
                      <div class="guidance-head">
                        <strong class="guidance-label">{{ priceGuidance.label }}</strong>
                        <span class="hint">vs market <BngIcon class="cur" :type="icons.beamCurrency" />{{ formatPrice(garage.marketValue) }}</span>
                      </div>
                      <div class="guidance-bar"><span :style="{ transform: `scaleX(${guidanceScale})` }" /></div>
                      <p class="hint guidance-desc">{{ priceGuidance.description }}</p>
                    </div>

                    <div class="action-row">
                      <HouseButton class="grow list-confirm" variant="primary" binding="ok" :disabled="!listingPrice || listingPrice <= 0" @click="confirmListing(garage)">
                        List for sale
                      </HouseButton>
                      <HouseButton variant="quiet" binding="back" @click="closeListingForm">Cancel</HouseButton>
                    </div>
                  </div>

                  <!-- Collapsed: List button -->
                  <template v-else>
                    <HouseButton
                      block
                      class="list-start"
                      :icon="icons.carCoins"
                      :disabled="!garage.canSell"
                      :title="!garage.canSell ? (garage.vehicleCount > 0 ? 'Remove all vehicles from this garage first' : 'Cannot sell this garage') : ''"
                      @click="startListing(garage)">
                      List for sale
                    </HouseButton>
                    <p v-if="!garage.canSell && garage.vehicleCount > 0" class="hint with-icon">
                      <BngIcon class="line-icon" :type="icons.car" />{{ vehiclesLeftText(garage) }}
                    </p>
                  </template>
                </div>
              </div>
            </article>
          </div>
        </div>
      </template>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, computed, nextTick, onMounted, onUnmounted, watch } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon, icons } from '@/common/components/base'
import { vBngTextInput, vBngUiNavScroll } from '@/common/directives'
import { HouseButton, openHouseConfirmation } from '../components/house/index.js'
import ComputerWrapper from './ComputerWrapper.vue'
import useControls from '@/services/controls'
import { useScreenEntry, refocusIfLost } from '../composables/useScreenEntryFocus'

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const events = useEvents()

const garages = ref([])
const loading = ref(true)
const expandedGarage = ref(null)
const listingPrice = ref(null)
const priceGuidance = ref(null)
const priceInputRef = ref(null)

const formatPrice = (value) => {
  if (value === null || value === undefined) return '0'
  return Math.floor(value).toLocaleString('en-US')
}

const guidanceClass = ref('')
const guidanceWidth = ref('50%')

// ---- view helpers (display only)
const priceSteps = [
  { amount: -10000, label: '−10k' },
  { amount: -1000, label: '−1k' },
  { amount: -100, label: '−100' },
  { amount: 100, label: '+100' },
  { amount: 1000, label: '+1k' },
  { amount: 10000, label: '+10k' },
]
const listedCount = computed(() => garages.value.filter(g => g.isListed).length)
const totalOffers = computed(() => garages.value.reduce((sum, g) => sum + (Number(g.offerCount) || 0), 0))
const portfolioValue = computed(() => garages.value.reduce((sum, g) => sum + (Number(g.marketValue) || 0), 0))
const guidanceScale = computed(() => Math.min(1, Math.max(0, (parseFloat(guidanceWidth.value) || 0) / 100)))
const hasTags = (garage) => garage.isListed || garage.offerCount > 0 || garage.canReclaim || garage.isRented || garage.isStarter || garage.isGranted
const vehiclesLeftText = (garage) => `${garage.vehicleCount} vehicle${garage.vehicleCount !== 1 ? 's' : ''} still in garage`

const loadGarages = async () => {
  // only the first load swaps the cards for the loading line; later refreshes keep them mounted so a
  // controller keeps its place
  loading.value = !garages.value.length
  try {
    const data = await lua.overhaul_career_garage_garageManager.getOwnedGaragesListingData()
    garages.value = data || []
  } catch (e) {
    garages.value = []
  }
  loading.value = false
}

const startListing = (garage) => {
  expandedGarage.value = garage.garageId
  listingPrice.value = garage.marketValue
  priceGuidance.value = null
  updateGuidance(garage)
  nextTick(() => {
    // a pad cannot type (and focusing the field would turn on CEF typing): it lands on the price steps,
    // with the market value already filled in; mouse / keyboard users get the field as before
    if (useControls().focusIfController) {
      refocusIfLost(() => cardEl(garage.garageId)?.querySelector('.listing-form .step'), { force: true })
      return
    }
    // the ref sits inside v-for, so Vue hands back an array
    const input = [].concat(priceInputRef.value || [])[0]
    if (input && input.focus) input.focus()
  })
}

const cardEl = (garageId) => document.querySelector(`.listings [data-garage-key="${garageId}"]`)

// Cancel / B close the form and put a pad back on that garage's List for sale
const closeListingForm = () => {
  const id = expandedGarage.value
  expandedGarage.value = null
  refocusIfLost(() => cardEl(id)?.querySelector('.list-start'), { force: true })
}

const adjustPrice = (amount, garage) => {
  const newPrice = Math.max(1000, (listingPrice.value || 0) + amount)
  listingPrice.value = newPrice
  updateGuidance(garage)
}

const updateGuidance = async (garage) => {
  if (!listingPrice.value || listingPrice.value <= 0) {
    priceGuidance.value = null
    return
  }
  try {
    const data = await lua.overhaul_career_garage_garageManager.getGarageListingPriceGuidance(garage.computerId, listingPrice.value)
    if (data) {
      priceGuidance.value = data
      const ratio = data.marketRatio || 1
      if (ratio < 0.98) {
        guidanceClass.value = 'guidance-low'
        guidanceWidth.value = Math.max(10, ratio * 50) + '%'
      } else if (ratio <= 1.10) {
        guidanceClass.value = 'guidance-fair'
        guidanceWidth.value = '60%'
      } else if (ratio <= 1.30) {
        guidanceClass.value = 'guidance-high'
        guidanceWidth.value = '80%'
      } else {
        guidanceClass.value = 'guidance-extreme'
        guidanceWidth.value = '95%'
      }
    }
  } catch (e) {
    priceGuidance.value = null
  }
}

const confirmListing = async (garage) => {
  if (!listingPrice.value || listingPrice.value <= 0) return
  await lua.overhaul_career_garage_garageManager.listGarageForSale(garage.computerId, listingPrice.value)
  expandedGarage.value = null
  listingPrice.value = null
  priceGuidance.value = null
  await loadGarages()
}

const removeListing = async (garage) => {
  await lua.overhaul_career_garage_property_realEstateNegotiation.removePropertyListing(garage.garageId)
  await loadGarages()
}

const moveOutTitle = (garage) => {
  if (garage?.canMoveOut) return 'Give up access with no refund'
  if (garage?.vehicleCount > 0) return 'Remove all vehicles from this garage first'
  return 'Cannot move out of this garage'
}

const confirmMoveOut = async (garage) => {
  if (!garage?.canMoveOut || !garage?.garageId) return
  const ok = await openHouseConfirmation(
    'Move Out',
    `Move out of ${garage.name || 'this garage'}?\n\nYou will lose access with no refund. You can reclaim it for free later from Real Estate.`,
    [
      { label: 'Move out', value: true, extras: { destructive: true } },
      { label: 'Cancel', value: false, extras: { cancel: true } },
    ]
  )
  if (!ok) return
  await lua.overhaul_career_garage_garageManager.moveOutOfGarage(garage.garageId)
  await loadGarages()
}

const confirmReclaim = async (garage) => {
  if (!garage?.canReclaim || !garage?.garageId) return
  const ok = await openHouseConfirmation(
    'Reclaim Garage',
    `Reclaim ${garage.name || 'this garage'} for free?`
  )
  if (!ok) return
  await lua.overhaul_career_garage_garageManager.reclaimGrantedGarage(garage.garageId)
  await loadGarages()
}

const viewOffers = (garage) => {
  lua.extensions.ui_router.navigate('garage-offers', { garageId: garage.garageId })
}

const goBack = () => {
  // B unwinds the open listing form before it leaves the screen
  if (expandedGarage.value != null) return closeListingForm()
  lua.extensions.ui_router.back()
}

// Controller: after a refresh (list / remove / move out / reclaim) put focus back on the same garage,
// else the first action on the page
let lastGarageKey = null
const noteFocus = () => {
  const key = document.activeElement?.closest?.('[data-garage-key]')?.dataset.garageKey
  if (key) lastGarageKey = key
}
const pickGarageFocus = () =>
  cardEl(lastGarageKey)?.querySelector('.card-actions button:not([disabled])') ||
  document.querySelector('.listings .card-actions button:not([disabled])')
watch([garages, expandedGarage], noteFocus, { flush: 'pre' })
watch(garages, () => refocusIfLost(pickGarageFocus), { flush: 'post' })
let entryDone = false
watch(loading, isLoading => {
  if (isLoading || entryDone) return
  entryDone = true
  // mod route: wake the screen scope so the d-pad works at once
  focusScreenEntry()
}, { flush: 'post' })

onMounted(() => {
  events.on('garageListingsUpdated', loadGarages)
  loadGarages()
})

onUnmounted(() => {
  events.off('garageListingsUpdated', loadGarages)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* near-black card under the screen heading, top-left; em off a resolution-scaled font */
.listings.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  width: min(66em, 100%);
  max-height: 100%;
  margin: 0;
  overflow: hidden;
  color: #fff;
  background: rgba(var(--bng-off-black-rgb), 0.9);
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

.state {
  padding: 1.6em 1.2em;
}
.state.hint {
  font-size: 0.95em;
}
.empty-icon {
  font-size: 2.2em;
  color: var(--faint);
}

/* ---- portfolio summary */
.summary {
  flex: 0 0 auto;
  display: flex;
  flex-wrap: wrap;
  gap: 0.6em 2.4em;
  padding: 1em 1.2em 0.85em;
  border-bottom: 1px solid var(--line);
  .fact-value {
    font-size: 1.25em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
}

/* ---- cards */
.garages {
  flex: 1 1 auto;
  min-height: 0;
  padding: 1em 0.5em 1.1em 1.2em;
}
.garages-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(19.5em, 1fr));
  gap: 0.8em;
  // cards in a row share one height (a listed garage has an extra action row); actions sit at the bottom
  align-items: stretch;
  padding-right: 0.3em;
}

.garage-card {
  display: flex;
  flex-direction: column;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--panel);
  &:hover,
  &:focus-within {
    background: var(--panel-2);
  }
}

/* photo first: 16:9, short tags top-left on a dark chip */
.card-photo {
  position: relative;
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  background: var(--photo);
  overflow: hidden;
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}
.photo-fallback {
  font-size: 2.6em;
  color: rgba(255, 255, 255, 0.22);
}
.photo-tags {
  position: absolute;
  top: 0.5em;
  left: 0.5em;
  right: 0.5em;
  display: flex;
  flex-wrap: wrap;
  gap: 0.35em;
}
.photo-tag {
  padding: 0.42em 0.55em 0.18em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.8);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  &.listed {
    color: var(--money);
  }
}

.card-body {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: 0.7em;
  min-width: 0;
  padding: 0.8em 0.9em 0.9em;
}

/* name biggest, value gold second, details faint */
.card-head {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 0.4em 0.9em;
  align-items: start;
}
.card-title {
  display: grid;
  gap: 0.25em;
  min-width: 0;
}
.card-name {
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}
.card-place {
  display: flex;
  align-items: center;
  gap: 0.4em;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
}
.card-value {
  display: grid;
  justify-items: end;
  gap: 0.15em;
  text-align: right;
  .caption {
    font-size: 0.68em;
  }
  .value {
    color: var(--money);
    font-size: 1.15em;
    font-weight: 800;
    line-height: 1.1;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .hint {
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
}

.card-specs {
  display: grid;
  gap: 0.3em;
}
.spec {
  display: flex;
  align-items: center;
  gap: 0.5em;
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.line-icon {
  flex: 0 0 auto;
  width: 1.25em;
  font-size: 1.15em;
  text-align: center;
  color: var(--faint);
}

.card-actions {
  display: grid;
  gap: 0.5em;
  margin-top: auto;
  padding-top: 0.15em;
}
.action-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45em;
  > .grow {
    flex: 1 1 auto;
  }
}
.hint {
  line-height: 1.35;
  &.with-icon {
    display: flex;
    align-items: center;
    gap: 0.4em;
    .line-icon {
      font-size: 1.1em;
    }
  }
}

/* ---- listing form */
.listing-form {
  display: grid;
  gap: 0.55em;
  padding: 0.8em;
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.28);
  animation: form-in 0.18s ease-out;
}
@keyframes form-in {
  from {
    opacity: 0;
    transform: translateY(-0.3em);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

.price-field {
  display: flex;
  align-items: center;
  gap: 0.25em;
  padding: 0 0.8em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  &:focus-within {
    box-shadow: var(--focus);
  }
}
.currency-sign {
  color: var(--money);
  font-size: 1.3em;
  font-weight: 800;
  opacity: 0.75;
}
.price-input {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  padding: 0.6em 0 0.45em;
  border: 0;
  outline: none;
  background: transparent;
  color: var(--money);
  font: inherit;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1;
  font-variant-numeric: tabular-nums;
  -moz-appearance: textfield;
  appearance: textfield;
  &::placeholder {
    color: var(--faint);
  }
  &::-webkit-inner-spin-button,
  &::-webkit-outer-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }
}

.steps {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 0.3em;
  .step {
    padding-left: 0.2em;
    padding-right: 0.2em;
    font-variant-numeric: tabular-nums;
  }
}

/* price guidance: tone on the label and bar only; red only when the price is unrealistic */
.guidance {
  display: grid;
  gap: 0.4em;
  padding: 0.2em 0 0.1em;
  --tone: rgba(255, 255, 255, 0.75);
  &.guidance-fair {
    --tone: var(--ok);
  }
  &.guidance-high {
    --tone: var(--warn);
  }
  &.guidance-extreme {
    --tone: var(--bad);
  }
}
.guidance-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  .hint {
    font-variant-numeric: tabular-nums;
  }
}
.guidance-label {
  color: var(--tone);
  font-size: 0.95em;
  font-weight: 800;
}
.guidance-bar {
  height: 0.4em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  > span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--tone);
    transform-origin: left center;
    transition: transform 0.25s ease-out;
  }
}
.guidance-desc {
  font-size: 0.82em;
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
