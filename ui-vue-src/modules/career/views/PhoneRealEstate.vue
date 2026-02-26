<template>
  <PhoneWrapper app-name="Real Estate" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="re-app">
      <!-- Not in career -->
      <div v-if="!careerActive && loaded" class="empty-state">
        <p>Start a career to browse properties.</p>
      </div>

      <!-- Loading -->
      <div v-if="!loaded" class="empty-state">
        <p>Loading properties...</p>
      </div>

      <template v-if="careerActive && loaded">
        <!-- Toolbar -->
        <div class="toolbar">
          <div class="view-toggle">
            <button :class="{ active: viewMode === 'list' }" @click="viewMode = 'list'">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
              List
            </button>
            <button :class="{ active: viewMode === 'map' }" @click="viewMode = 'map'">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/></svg>
              Map
            </button>
          <button :class="{ active: viewMode === 'listings' }" @click="viewMode = 'listings'">
            Listings
          </button>
          <button :class="{ active: viewMode === 'mortgages' }" @click="viewMode = 'mortgages'">
            Mortgages
          </button>
          </div>
          <div v-if="viewMode === 'list'" class="toolbar-row-2">
            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: filterOpen }" @click="filterOpen = !filterOpen; sortOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>
                Filter
                <svg class="dropdown-chevron" :class="{ open: filterOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
              </button>
              <div v-if="filterOpen" class="dropdown-panel filter-panel" ref="filterPanelRef" tabindex="-1" @mousedown.stop>
                <label class="filter-opt">
                  <span class="custom-checkbox" :class="{ checked: filterForm.affordable }"><span class="custom-checkbox-dot"></span></span>
                  <input type="checkbox" v-model="filterForm.affordable" class="sr-only" />
                  Affordable only
                </label>
                <label class="filter-opt">
                  <span class="custom-checkbox" :class="{ checked: filterForm.notOwned }"><span class="custom-checkbox-dot"></span></span>
                  <input type="checkbox" v-model="filterForm.notOwned" class="sr-only" />
                  Not Owned
                </label>
                <div class="filter-row">
                  <label>Price</label>
                  <div class="filter-inputs-stacked">
                    <input ref="firstFilterInputRef" type="number" v-model.number="filterForm.priceMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input />
                    <input type="number" v-model.number="filterForm.priceMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input />
                  </div>
                </div>
                <div class="filter-row">
                  <label>Slots</label>
                  <div class="filter-inputs-stacked">
                    <input type="number" v-model.number="filterForm.slotsMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input />
                    <input type="number" v-model.number="filterForm.slotsMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input />
                  </div>
                </div>
                <div class="filter-row">
                  <label>Dist (m)</label>
                  <div class="filter-inputs-stacked">
                    <input type="number" v-model.number="filterForm.distMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input />
                    <input type="number" v-model.number="filterForm.distMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input />
                  </div>
                </div>
                <button class="filter-clear" @click="clearFilters">Clear</button>
              </div>
            </div>
            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: sortOpen }" @click="sortOpen = !sortOpen; filterOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="14" y2="12"/><line x1="4" y1="18" x2="9" y2="18"/></svg>
                Sort
                <svg class="dropdown-chevron" :class="{ open: sortOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
              </button>
              <div v-if="sortOpen" class="dropdown-panel sort-panel">
                <div class="sort-grid">
                  <span class="sort-label">By</span>
                  <div class="sort-options">
                    <button v-for="f in sortFields" :key="f.key" class="sort-opt" :class="{ active: sortBy === f.key }" @click="sortBy = f.key">{{ f.label }}</button>
                  </div>
                  <span class="sort-label">Order</span>
                  <div class="sort-options">
                    <button class="sort-opt" :class="{ active: sortAsc }" @click="sortAsc = true">Asc</button>
                    <button class="sort-opt" :class="{ active: !sortAsc }" @click="sortAsc = false">Desc</button>
                  </div>
                </div>
              </div>
            </div>
            <span class="toolbar-count">{{ listFilteredGarages.length }} shown</span>
          </div>
        </div>

        <!-- LIST VIEW -->
        <div class="list-view" v-if="viewMode === 'list'">
          <div v-if="listFilteredGarages.length === 0" class="empty-state small">No properties match filters.</div>
          <div
            v-for="garage in listFilteredGarages"
            :key="garage.id"
            class="card"
            :class="{ owned: garage.owned }"
            @click="toggleExpand(garage.id)"
          >
            <div class="card-img">
              <img v-if="garage.preview && !imgFailed(garage.id)" :src="garage.preview" alt="" @error="onImgError(garage)" />
              <div v-else class="card-img-ph">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
                <span>No preview</span>
              </div>
              <div class="card-img-fade"></div>
              <div class="card-badges">
                <span v-if="garage.owned" class="badge owned">OWNED</span>
                <span v-else-if="garage.starterGarage" class="badge free">FREE</span>
              </div>
              <div class="card-price" v-if="!garage.owned">{{ garage.starterGarage ? 'FREE' : '$' + formatPrice(garage.price) }}</div>
            </div>
            <div class="card-body">
              <div class="card-info">
                <span class="card-name">{{ garage.name }}</span>
                <div class="card-meta">
                  <span class="meta-item">
                    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="3" width="15" height="13" rx="2"/><path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/></svg>
                    <template v-if="garage.owned">{{ garage.vehicleCount }}/{{ garage.capacity }}</template>
                    <template v-else>{{ garage.capacity }} slots</template>
                  </span>
                  <span class="meta-item" v-if="garage.distance >= 0">
                    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                    {{ formatDistance(garage.distance) }}
                  </span>
                </div>
              </div>
              <svg class="chevron" :class="{ open: expandedId === garage.id }" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.35)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
            </div>
            <div class="card-expand" v-if="expandedId === garage.id">
              <p class="card-desc" v-if="garage.description && cleanDescription(garage.description)">{{ cleanDescription(garage.description) }}</p>
              <div class="card-actions">
                <button class="act-btn route" @click.stop="setRoute(garage)">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                  Set Route
                </button>
              </div>
            </div>
          </div>
        </div>

        <!-- MAP VIEW -->
        <div class="map-view" v-if="viewMode === 'map'" ref="mapContainer">
          <div
            class="map-layers"
            @pointerdown="onMapPointerDown"
            @pointermove="onMapPointerMove"
            @pointerup="onMapPointerUp"
            @pointercancel="onMapPointerUp"
            @pointerleave="onMapPointerUp"
            @wheel.prevent="onMapWheel"
          >
            <svg class="map-layer terrain-layer"></svg>
            <svg class="map-layer roads-layer"></svg>
            <svg class="map-layer vehicle-layer"></svg>
            <svg class="map-layer marker-layer" :viewBox="markerViewBox">
              <g v-for="item in clusteredMarkers" :key="'m-'+item.cluster[0].id"
                :transform="'translate(' + (-item.posX) + ',' + item.posY + ') scale(' + zoomFactor + ')'"
                class="garage-marker"
                :class="{ selected: selectedGarage && item.cluster.some(g => g.id === selectedGarage.id), cluster: item.count > 1 }"
                @click.stop="selectMarker(item.cluster[0])"
              >
                <circle r="18" class="marker-bg" />
                <circle r="12" class="marker-dot" :class="{ owned: item.count === 1 && item.cluster[0].owned }" />
                <template v-if="item.count > 1">
                  <text y="0" text-anchor="middle" dominant-baseline="middle" class="marker-label marker-count">{{ item.count }}</text>
                </template>
                <template v-else>
                  <svg x="-7.5" y="-7.5" width="15" height="15" viewBox="0 0 24 24" fill="white" stroke="none"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
                  <text y="28" text-anchor="middle" class="marker-label">{{ item.cluster[0].owned ? 'OWNED' : (item.cluster[0].starterGarage ? 'FREE' : '$' + formatPrice(item.cluster[0].price)) }}</text>
                </template>
              </g>
            </svg>
          </div>

          <div class="map-carousel-wrap">
            <div
              class="map-carousel-viewport"
              ref="carouselViewportRef"
              @pointerdown.capture="onCarouselPointerDown"
              @click="onCarouselViewportClick"
            >
              <div
                class="map-carousel-track"
                :class="{ 'no-transition': isDraggingCarousel || isWrappingCarousel }"
                :style="{ '--carousel-duration': carouselTransitionDuration + 's', '--carousel-slide-width': carouselSlideWidth + 'px', transform: `translateX(${carouselOffset}px)` }"
              >
                <article
                  v-for="(garage, idx) in carouselGarages"
                  :key="'c-' + garage.id + '-' + idx"
                  class="map-slide"
                  :class="{ selected: selectedGarage && selectedGarage.id === garage.id }"
                  :style="{ flex: '0 0 ' + carouselSlideWidth + 'px', width: carouselSlideWidth + 'px' }"
                >
                <div class="map-slide-img">
                  <img v-if="garage.preview && !imgFailed(garage.id)" :src="garage.preview" alt="" draggable="false" @error="onImgError(garage)" />
                  <div v-else class="card-img-ph small">
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
                  </div>
                  <div class="map-slide-img-fade"></div>
                  <div class="map-slide-badges">
                    <span v-if="garage.owned" class="badge owned">OWNED</span>
                    <span v-else-if="garage.starterGarage" class="badge free">FREE</span>
                  </div>
                  <div class="map-slide-price-overlay" v-if="!garage.owned">{{ garage.starterGarage ? 'FREE' : '$' + formatPrice(garage.price) }}</div>
                </div>
                <div class="map-slide-body">
                  <div class="map-slide-top">
                    <span class="map-slide-name">{{ garage.name }}</span>
                  </div>
                    <div class="map-slide-meta-row">
                    <div class="map-slide-meta">
                      <span>
                        <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="3" width="15" height="13" rx="2"/><path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/></svg>
                        <template v-if="garage.owned">{{ garage.vehicleCount }}/{{ garage.capacity }}</template>
                        <template v-else>{{ garage.capacity }} slots</template>
                      </span>
                      <span v-if="garage.distance >= 0">
                        <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                        {{ formatDistance(garage.distance) }}
                      </span>
                    </div>
                    <button class="act-btn route" @click.stop="setRoute(garage)">
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                      Route
                    </button>
                  </div>
                </div>
                </article>
              </div>
            </div>
          </div>
        </div>

        <!-- MORTGAGES VIEW -->
        <div class="listings-view" v-if="viewMode === 'mortgages'">
          <div v-if="mortgagesLoading" class="empty-state small">Loading mortgages...</div>
          <div v-else-if="mortgages.length === 0" class="empty-state small">No active mortgages.</div>
          <div
            v-for="mortgage in mortgages"
            :key="mortgage.garageId"
            class="mortgage-card"
            :class="mortgageStatusClass(mortgage)"
          >
            <div class="mortgage-card-header">
              <div class="mortgage-card-info">
                <span class="mortgage-prop-name">{{ mortgage.propertyName }}</span>
                <span class="mortgage-card-meta">{{ mortgage.remainingPayments }} payments left</span>
              </div>
              <div class="mortgage-strike-dots" v-if="mortgage.strikes > 0">
                <span class="strike-dot" v-for="s in mortgage.strikes" :key="s"></span>
              </div>
            </div>
            <div class="mortgage-card-body">
              <div class="mortgage-stat">
                <span class="mortgage-stat-label">Monthly</span>
                <span class="mortgage-stat-val">${{ formatPrice(mortgage.monthlyPayment) }}</span>
              </div>
              <div class="mortgage-stat">
                <span class="mortgage-stat-label">Remaining</span>
                <span class="mortgage-stat-val">${{ formatPrice(mortgage.remainingBalance) }}</span>
              </div>
              <div class="mortgage-stat">
                <span class="mortgage-stat-label">Rate</span>
                <span class="mortgage-stat-val">{{ mortgage.interestRate ? mortgage.interestRate.toFixed(1) : '0' }}%</span>
              </div>
            </div>
            <div class="mortgage-card-warning" v-if="mortgage.strikes === 1">
              ⚠ 1 missed payment — next miss may increase penalties.
            </div>
            <div class="mortgage-card-warning danger" v-if="mortgage.strikes >= 2">
              ⛔ {{ mortgage.strikes }} missed payments — property at risk of repossession!
            </div>
            <div class="mortgage-card-actions">
              <button class="act-btn route" @click="payoffMortgage(mortgage.garageId)">
                Early Payoff (${{ formatPrice(mortgage.remainingBalance) }})
              </button>
            </div>
          </div>
        </div>

        <!-- LISTINGS VIEW -->
        <div class="listings-view" v-if="viewMode === 'listings'">
          <button v-if="listingsSubView === 'offers'" class="listings-back-bar" @click="setListingsSubView('owned')">
            &larr; Back to properties
          </button>

          <template v-if="listingsSubView === 'owned'">
            <div v-if="ownedListings.length === 0" class="empty-state small">No properties owned.</div>
            <div
              v-for="garage in ownedListings"
              :key="garage.garageId"
              class="listings-card"
            >
              <div class="listings-card-img">
                <img v-if="garage.preview && !imgFailed(garage.garageId)" :src="garage.preview" alt="" @error="onImgError({ id: garage.garageId })" />
                <div v-else class="card-img-ph">
                  <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
                  <span>No preview</span>
                </div>
                <div class="card-img-fade"></div>
                <div class="card-badges">
                  <span v-if="garage.isListed" class="badge listed">LISTED</span>
                  <span v-if="garage.isStarter" class="badge starter">STARTER</span>
                </div>
                <div class="listings-card-price">${{ formatPrice(garage.marketValue) }}</div>
              </div>

              <div class="listings-card-body">
                <div class="listings-card-info">
                  <span class="listings-name">{{ garage.name }}</span>
                  <div class="listings-card-meta">
                    <span class="meta-item">
                      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="3" width="15" height="13" rx="2"/><path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/></svg>
                      {{ garage.vehicleCount }}/{{ garage.capacity }}
                    </span>
                    <span v-if="garage.offerCount" class="meta-item offer-count">{{ garage.offerCount }} offer(s)</span>
                    <span v-if="garage.isListed" class="meta-item listing-active">Listed: ${{ formatPrice(garage.askingPrice) }}</span>
                    <span v-else class="meta-item">Not listed</span>
                  </div>
                </div>
              </div>

              <div class="listings-actions" v-if="!garage.isListed">
                <div class="listing-price-row">
                  <input
                    v-model.number="listingPrices[garage.garageId]"
                    type="number"
                    min="0"
                    placeholder="Asking price"
                    class="listing-price-input"
                    v-bng-text-input
                  />
                  <button class="act-btn route" @click="getGuidance(garage)">Check Price</button>
                </div>
                <p v-if="listingGuidance[garage.garageId]" class="listing-guidance" :class="`guidance-${listingGuidance[garage.garageId].tier || 'fair'}`">
                  {{ listingGuidance[garage.garageId].label || 'Price check' }}: {{ listingGuidance[garage.garageId].description || '' }}
                </p>
                <button
                  class="act-btn negotiate listings-full-btn"
                  :disabled="!garage.canSell"
                  @click="listGarageForSale(garage)"
                >
                  List for Sale
                </button>
              </div>

              <div class="listings-actions" v-else>
                <div class="listings-listed-row">
                  <button class="act-btn negotiate" @click="openOwnedOffers(garage)">
                    View Offers<span v-if="garage.offerCount"> ({{ garage.offerCount }})</span>
                  </button>
                  <button class="act-btn route" @click="removeOwnedListing(garage)">
                    Remove Listing
                  </button>
                </div>
              </div>
            </div>
          </template>

          <template v-else-if="listingsSubView === 'offers'">
            <div class="offer-shell">
              <div v-if="!selectedOwnedGarage" class="empty-state small">No selected listing.</div>
              <template v-else>
                <div class="listings-offers-header">
                  <div class="offers-header-info">
                    <span class="listings-name">{{ selectedOwnedGarage.name }}</span>
                    <span class="listings-meta">Asking: ${{ formatPrice(selectedOwnedGarage.askingPrice || 0) }}</span>
                    <span class="listings-meta">Market: ${{ formatPrice(selectedOwnedGarage.marketValue || 0) }}</span>
                  </div>
                  <span class="offers-count-badge" v-if="selectedOwnedOffers.length">{{ selectedOwnedOffers.length }}</span>
                </div>
                <div v-if="!selectedOwnedOffers.length" class="empty-state small">No offers yet.</div>
                <div
                  v-for="offer in selectedOwnedOffers"
                  :key="offer.index"
                  class="offers-card"
                >
                  <div class="offer-head">
                    <span class="offer-buyer">{{ offer.buyerName }}</span>
                    <span v-if="offer.negotiationPossible" class="offer-status status-open">Open</span>
                    <span v-else class="offer-status status-closed">Closed</span>
                  </div>
                  <div class="offer-price">
                    <span class="price-label">Offer:</span>
                    <span v-if="offer.negotiatedPrice">
                      <s>${{ formatPrice(offer.value) }}</s>
                      <strong>${{ formatPrice(offer.negotiatedPrice) }}</strong>
                    </span>
                    <span v-else>${{ formatPrice(offer.value) }}</span>
                  </div>
                  <div class="offer-actions">
                    <button class="act-btn negotiate" @click="acceptOwnedOffer(offer)">Accept</button>
                    <button
                      class="act-btn route"
                      :disabled="!offer.negotiationPossible"
                      @click="negotiateOwnedOffer(offer)"
                    >
                      Negotiate
                    </button>
                    <button class="act-btn decline" @click="declineOwnedOffer(offer)">Decline</button>
                  </div>
                </div>
              </template>
            </div>
          </template>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useRoute } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { useMinimapStore } from '../stores/minimapStore'
import { vBngTextInput } from '@/common/directives'
import PhoneWrapper from './PhoneWrapper.vue'

defineOptions({ directives: { BngTextInput: vBngTextInput } })

const events = useEvents()
const minimapStore = useMinimapStore()
const route = useRoute()

const garages = ref([])
const playerBalance = ref(0)
const careerActive = ref(true)
const loaded = ref(false)

const filterOpen = ref(false)
const sortOpen = ref(false)
const filterForm = reactive({
  affordable: false,
  notOwned: false,
  priceMin: null,
  priceMax: null,
  slotsMin: null,
  slotsMax: null,
  distMin: null,
  distMax: null,
})
const sortBy = ref('distance')
const sortAsc = ref(true)
const sortFields = [
  { key: 'price', label: 'Price' },
  { key: 'capacity', label: 'Slots' },
  { key: 'distance', label: 'Distance' },
]
const failedImages = reactive(new Set())

const viewMode = ref('map')
const listingsSubView = ref('owned')
const ownedListings = ref([])
const listingPrices = reactive({})
const listingGuidance = reactive({})
const selectedOwnedGarage = ref(null)
const selectedOwnedOffers = ref([])
const mortgages = ref([])
const mortgagesLoading = ref(false)

const expandedId = ref(null)
const selectedGarage = ref(null)
const mapContainer = ref(null)
const markerViewBox = ref('0 0 1000 1000')
const realEstateBaseViewBox = ref('0 0 1000 1000')
const panOffset = reactive({ x: 0, y: 0 })
const zoomFactor = ref(1)
const panState = reactive({
  active: false,
  moved: false,
  lastX: 0,
  lastY: 0,
  pointerId: null,
})
const suppressMarkerClickUntil = ref(0)
const filterPanelRef = ref(null)
const firstFilterInputRef = ref(null)
let resizeObserver = null
let carouselResizeObserver = null
let mapFocusAnimationFrame = null

const filteredGarages = computed(() => garages.value)

const listFilteredGarages = computed(() => {
  let list = garages.value
  const balance = playerBalance.value
  const f = filterForm

  if (f.affordable) {
    list = list.filter(g => g.owned || g.price <= balance)
  }
  if (f.notOwned) {
    list = list.filter(g => !g.owned)
  }
  if (f.priceMin != null && f.priceMin !== '') {
    const v = Number(f.priceMin)
    if (!isNaN(v)) list = list.filter(g => g.owned || g.price >= v)
  }
  if (f.priceMax != null && f.priceMax !== '') {
    const v = Number(f.priceMax)
    if (!isNaN(v)) list = list.filter(g => g.owned || g.price <= v)
  }
  if (f.slotsMin != null && f.slotsMin !== '') {
    const v = Number(f.slotsMin)
    if (!isNaN(v)) list = list.filter(g => g.capacity >= v)
  }
  if (f.slotsMax != null && f.slotsMax !== '') {
    const v = Number(f.slotsMax)
    if (!isNaN(v)) list = list.filter(g => g.capacity <= v)
  }
  if (f.distMin != null && f.distMin !== '') {
    const v = Number(f.distMin)
    if (!isNaN(v)) list = list.filter(g => g.distance < 0 || g.distance >= v)
  }
  if (f.distMax != null && f.distMax !== '') {
    const v = Number(f.distMax)
    if (!isNaN(v)) list = list.filter(g => g.distance < 0 || g.distance <= v)
  }

  const arr = [...list]
  const key = sortBy.value
  const asc = sortAsc.value
  arr.sort((a, b) => {
    let va = key === 'price' ? (a.owned ? 0 : a.price) : key === 'capacity' ? a.capacity : (a.distance < 0 ? 1e9 : a.distance)
    let vb = key === 'price' ? (b.owned ? 0 : b.price) : key === 'capacity' ? b.capacity : (b.distance < 0 ? 1e9 : b.distance)
    if (va < vb) return asc ? -1 : 1
    if (va > vb) return asc ? 1 : -1
    return 0
  })
  return arr
})

function clearFilters() {
  filterForm.affordable = false
  filterForm.notOwned = false
  filterForm.priceMin = null
  filterForm.priceMax = null
  filterForm.slotsMin = null
  filterForm.slotsMax = null
  filterForm.distMin = null
  filterForm.distMax = null
}

const carouselGarages = computed(() => {
  const list = filteredGarages.value
  if (list.length < 2) return list
  return [...list, ...list, ...list]
})

const carouselCycleLen = computed(() => filteredGarages.value.length)

const carouselViewportRef = ref(null)
const carouselWidth = ref(340)
const carouselSlideIndex = ref(0)
const carouselDragDelta = ref(0)
const carouselTransitionDuration = ref(0.35)
const isDraggingCarousel = ref(false)
const isWrappingCarousel = ref(false)
const carouselPointerStart = reactive({ x: 0 })
let carouselPointerId = null

const carouselSlideWidth = computed(() => Math.max(292, carouselWidth.value - 28))
const carouselSlideStep = computed(() => carouselSlideWidth.value + 10)

const carouselOffset = computed(() => {
  return -carouselSlideIndex.value * carouselSlideStep.value + carouselDragDelta.value
})

const suppressCarouselClickUntil = ref(0)

const CLUSTER_RADIUS_PX = 50
const mapContainerSize = ref({ width: 400, height: 400 })

function worldToPixelDist(dxWorld, dyWorld, viewBox, containerW, containerH) {
  const scaleX = containerW / viewBox.w
  const scaleY = containerH / viewBox.h
  return Math.hypot(dxWorld * scaleX, dyWorld * scaleY)
}

function clusterGarages(garages, viewBoxStr, containerSize) {
  const result = []
  const assigned = new Set()
  const box = parseViewBox(viewBoxStr)
  const cw = Math.max(1, containerSize.width)
  const ch = Math.max(1, containerSize.height)

  for (const g of garages) {
    if (assigned.has(g.id)) continue
    const cluster = [g]
    assigned.add(g.id)
    let changed = true
    while (changed) {
      changed = false
      for (const other of garages) {
        if (assigned.has(other.id)) continue
        for (const c of cluster) {
          const distPx = worldToPixelDist(other.posX - c.posX, other.posY - c.posY, box, cw, ch)
          if (distPx <= CLUSTER_RADIUS_PX) {
            cluster.push(other)
            assigned.add(other.id)
            changed = true
            break
          }
        }
      }
    }
    const posX = cluster.reduce((s, x) => s + x.posX, 0) / cluster.length
    const posY = cluster.reduce((s, x) => s + x.posY, 0) / cluster.length
    result.push({ cluster, posX, posY, count: cluster.length })
  }
  return result
}

const clusteredMarkers = computed(() =>
  clusterGarages(filteredGarages.value, markerViewBox.value, mapContainerSize.value)
)

const refreshMortgages = async () => {
  mortgagesLoading.value = true
  try {
    const data = await lua.career_modules_propertyMortgage.getAllMortgages()
    // Lua returns {garageId: mortgageObj, ...} — convert to array
    if (data && typeof data === 'object' && !Array.isArray(data)) {
      mortgages.value = Object.entries(data).map(([gId, m]) => ({
        garageId: gId,
        propertyName: m.garageId || gId,
        monthlyPayment: m.monthlyPayment || 0,
        remainingBalance: m.remainingBalance || 0,
        remainingPayments: m.remainingPayments || 0,
        interestRate: (m.interestRate || 0) * 100,
        strikes: m.missedPayments || 0,
      }))
    } else {
      mortgages.value = []
    }
  } catch (e) {
    mortgages.value = []
  }
  mortgagesLoading.value = false
}

const payoffMortgage = async (garageId) => {
  await lua.career_modules_propertyMortgage.payoffMortgage(garageId)
  await refreshMortgages()
}

const mortgageStatusClass = (mortgage) => {
  if (mortgage.strikes >= 2) return 'mortgage-danger'
  if (mortgage.strikes === 1) return 'mortgage-warning'
  return 'mortgage-ok'
}

function formatPrice(price) {
  if (price >= 1000000) return (price / 1000000).toFixed(1) + 'M'
  if (price >= 1000) return (price / 1000).toFixed(0) + 'K'
  return price.toString()
}

function formatDistance(meters) {
  if (meters < 0) return '--'
  if (meters >= 1000) return (meters / 1000).toFixed(1) + ' km'
  return Math.round(meters) + ' m'
}

const defaultListingPrice = (garage) => {
  return Number(garage?.askingPrice) > 0 ? Number(garage.askingPrice) : Math.max(0, Number(garage?.marketValue) || 0)
}

const syncListingInputs = () => {
  for (const garage of ownedListings.value) {
    if (!garage) continue
    const id = garage.garageId
    if (listingPrices[id] == null) {
      listingPrices[id] = defaultListingPrice(garage)
    }
  }
}

const setListingsSubView = (view) => {
  if (view === 'owned') {
    selectedOwnedOffers.value = []
    selectedOwnedGarage.value = null
  }
  listingsSubView.value = view
}

function getNearestGarage(list) {
  if (!Array.isArray(list) || !list.length) return null
  let nearest = null
  let nearestDistance = Infinity
  for (const garage of list) {
    const distance = Number(garage?.distance)
    const normalizedDistance = Number.isFinite(distance) && distance >= 0 ? distance : Infinity
    if (normalizedDistance < nearestDistance) {
      nearestDistance = normalizedDistance
      nearest = garage
    }
  }
  return nearest || list[0]
}

function cleanDescription(desc) {
  if (desc.startsWith('levels.')) return ''
  return desc
}

function toggleExpand(id) {
  expandedId.value = expandedId.value === id ? null : id
}

function selectMarker(garage) {
  if (Date.now() < suppressMarkerClickUntil.value) return
  focusGarage(garage, { centerMap: true, animateCenterMap: true })
}

function setRoute(garage) {
  lua.ui_phone_realEstate.setRouteToGarage(garage.id)
}

function openGarageListing(garage) {
  if (garage?.id) lua.career_modules_garageManager.showPurchaseGaragePrompt(garage.id)
}

function imgFailed(garageId) {
  return failedImages.has(garageId)
}

function onImgError(garage) {
  failedImages.add(garage.id)
}

const refreshOwnedListings = async () => {
  if (!lua.career_modules_garageManager?.getOwnedGaragesListingData) return
  const data = await lua.career_modules_garageManager.getOwnedGaragesListingData()
  ownedListings.value = Array.isArray(data) ? data : []
  syncListingInputs()
}

const openOwnedOffers = async (garage) => {
  if (!garage?.garageId) return
  const data = await lua.career_modules_garageManager.getGarageOffersData(garage.garageId)
  if (!data) {
    selectedOwnedGarage.value = { ...garage, garageId: garage.garageId }
    selectedOwnedOffers.value = []
  } else {
    selectedOwnedGarage.value = data
    selectedOwnedOffers.value = data.offers || []
  }
  listingsSubView.value = 'offers'
}

const getGuidance = async (garage) => {
  const askingPrice = Number(listingPrices[garage.garageId])
  const value = Number.isFinite(askingPrice) && askingPrice > 0 ? askingPrice : defaultListingPrice(garage)
  const data = await lua.career_modules_garageManager.getGarageListingPriceGuidanceByGarageId(garage.garageId, value)
  listingGuidance[garage.garageId] = data || null
}

const listGarageForSale = async (garage) => {
  if (!garage?.garageId) return
  const askingPrice = Number(listingPrices[garage.garageId])
  const value = Number.isFinite(askingPrice) && askingPrice > 0 ? askingPrice : defaultListingPrice(garage)
  await lua.career_modules_garageManager.listGarageForSaleByGarageId(garage.garageId, value)
  await refreshOwnedListings()
}

const removeOwnedListing = async (garage) => {
  if (!garage?.computerId) return
  await lua.career_modules_garageManager.removeGarageListing(garage.computerId)
  if (selectedOwnedGarage.value && selectedOwnedGarage.value.garageId === garage.garageId && listingsSubView.value === 'offers') {
    listingsSubView.value = 'owned'
    selectedOwnedGarage.value = null
    selectedOwnedOffers.value = []
  }
  await refreshOwnedListings()
}

const acceptOwnedOffer = async (offer) => {
  const garageId = selectedOwnedGarage.value?.garageId
  if (!garageId || !offer?.index) return
  await lua.career_modules_garageManager.acceptOffer(garageId, offer.index)
  await refreshOwnedListings()
  if (listingsSubView.value === 'offers') {
    listingsSubView.value = 'owned'
    selectedOwnedGarage.value = null
    selectedOwnedOffers.value = []
  }
}

const declineOwnedOffer = async (offer) => {
  const garageId = selectedOwnedGarage.value?.garageId
  if (!garageId || !offer?.index) return
  await lua.career_modules_garageManager.declineOffer(garageId, offer.index)
  await openOwnedOffers(selectedOwnedGarage.value)
}

const negotiateOwnedOffer = async (offer) => {
  const garageId = selectedOwnedGarage.value?.garageId
  if (!garageId || !offer?.index) return
  await lua.career_modules_realEstateNegotiation.startNegotiateSelling(garageId, offer.index, 'phone')
}

function parseViewBox(viewBoxString) {
  const raw = (viewBoxString || '0 0 1000 1000').split(' ').map(Number)
  if (raw.length !== 4 || raw.some(Number.isNaN)) {
    return { x: 0, y: 0, w: 1000, h: 1000 }
  }
  return { x: raw[0], y: raw[1], w: raw[2], h: raw[3] }
}

function buildWalkingZoomBaseViewBox() {
  const current = parseViewBox(minimapStore.viewBox)
  const centerX = current.x + current.w / 2
  const centerY = current.y + current.h / 2
  const minimapZoomFactor = Number(minimapStore.zoomFactor)
  const zoomFactorValue = Number.isFinite(minimapZoomFactor) && minimapZoomFactor > 0 ? minimapZoomFactor : 3
  const walkingZoomRadius = 50 * zoomFactorValue
  const width = walkingZoomRadius * 2
  const height = walkingZoomRadius * 2
  return `${centerX - width / 2} ${centerY - height / 2} ${width} ${height}`
}

function getMapBaseViewBox() {
  if (minimapStore.viewControlledBy === 'realEstate') return parseViewBox(realEstateBaseViewBox.value)
  return parseViewBox(minimapStore.viewBox)
}

function applyEffectiveViewBox() {
  const base = getMapBaseViewBox()
  const z = Math.max(0.25, Math.min(4, zoomFactor.value))
  const cx = base.x + panOffset.x + base.w / 2
  const cy = base.y + panOffset.y + base.h / 2
  const w = base.w * z
  const h = base.h * z
  const effective = `${cx - w / 2} ${cy - h / 2} ${w} ${h}`
  markerViewBox.value = effective
  if (minimapStore.svgLayers?.terrain) minimapStore.svgLayers.terrain.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.roads) minimapStore.svgLayers.roads.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.vehicles) minimapStore.svgLayers.vehicles.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.aux) minimapStore.svgLayers.aux.setAttribute('viewBox', effective)
}

function stopMapFocusAnimation() {
  if (mapFocusAnimationFrame != null) {
    cancelAnimationFrame(mapFocusAnimationFrame)
    mapFocusAnimationFrame = null
  }
}

function animateMapPanTo(targetX, targetY, durationMs = 320) {
  stopMapFocusAnimation()
  const startX = panOffset.x
  const startY = panOffset.y
  const dx = targetX - startX
  const dy = targetY - startY
  if (Math.abs(dx) < 0.001 && Math.abs(dy) < 0.001) {
    panOffset.x = targetX
    panOffset.y = targetY
    applyEffectiveViewBox()
    return
  }
  const startTime = performance.now()
  const step = (now) => {
    const t = Math.min(1, (now - startTime) / durationMs)
    const eased = 1 - Math.pow(1 - t, 3)
    panOffset.x = startX + dx * eased
    panOffset.y = startY + dy * eased
    applyEffectiveViewBox()
    if (t < 1) {
      mapFocusAnimationFrame = requestAnimationFrame(step)
    } else {
      mapFocusAnimationFrame = null
    }
  }
  mapFocusAnimationFrame = requestAnimationFrame(step)
}

function onMapWheel(event) {
  if (!mapContainer.value) return
  stopMapFocusAnimation()
  const delta = event.deltaY * 0.002
  zoomFactor.value = Math.max(0.1, Math.min(4, zoomFactor.value * (1 + delta)))
  applyEffectiveViewBox()
}

function onMapPointerDown(event) {
  stopMapFocusAnimation()
  panState.active = true
  panState.moved = false
  panState.lastX = event.clientX
  panState.lastY = event.clientY
  panState.pointerId = event.pointerId
}

function onMapPointerMove(event) {
  if (!panState.active || panState.pointerId !== event.pointerId || !mapContainer.value) return
  const dx = event.clientX - panState.lastX
  const dy = event.clientY - panState.lastY
  if (Math.abs(dx) > 2 || Math.abs(dy) > 2) panState.moved = true
  panState.lastX = event.clientX
  panState.lastY = event.clientY

  const rect = mapContainer.value.getBoundingClientRect()
  if (rect.width <= 0 || rect.height <= 0) return
  const box = parseViewBox(markerViewBox.value)
  const worldPerPixelX = box.w / rect.width
  const worldPerPixelY = box.h / rect.height
  panOffset.x -= dx * worldPerPixelX
  panOffset.y -= dy * worldPerPixelY
  applyEffectiveViewBox()
}

function onMapPointerUp(event) {
  if (panState.pointerId !== event.pointerId) return
  if (panState.moved) suppressMarkerClickUntil.value = Date.now() + 120
  panState.active = false
  panState.moved = false
  panState.pointerId = null
}

function scrollToGarageCard(garageId) {
  if (!garageId) return
  const list = filteredGarages.value
  const index = list.findIndex(g => g.id === garageId)
  if (index < 0) return
  const targetIdx = list.length >= 2 ? carouselCycleLen.value + index : index
  const delta = Math.abs(targetIdx - carouselSlideIndex.value)
  carouselTransitionDuration.value = delta > 1 ? Math.min(0.7, 0.3 + delta * 0.025) : 0.35
  carouselSlideIndex.value = targetIdx
}

function onCarouselPointerDown(event) {
  const viewport = event.currentTarget
  if (!viewport) return
  carouselPointerId = event.pointerId
  carouselPointerStart.x = event.clientX
  carouselDragDelta.value = 0
  isDraggingCarousel.value = false
  document.addEventListener('pointermove', onCarouselDocMove)
  document.addEventListener('pointerup', onCarouselDocUp)
  document.addEventListener('pointercancel', onCarouselDocUp)
}

function onCarouselDocMove(event) {
  if (event.pointerId !== carouselPointerId) return
  const dx = event.clientX - carouselPointerStart.x
  if (!isDraggingCarousel.value && Math.abs(dx) > 8) {
    isDraggingCarousel.value = true
    const viewport = carouselViewportRef.value
    if (viewport?.setPointerCapture) {
      try { viewport.setPointerCapture(event.pointerId) } catch (_) {}
    }
  }
  if (isDraggingCarousel.value) {
    event.preventDefault()
    carouselDragDelta.value = Math.max(-carouselSlideStep.value, Math.min(carouselSlideStep.value, dx))
  }
}

function onCarouselDocUp(event) {
  if (event.pointerId !== carouselPointerId) return
  const viewport = carouselViewportRef.value
  if (viewport?.releasePointerCapture) {
    try { viewport.releasePointerCapture(event.pointerId) } catch (_) {}
  }
  document.removeEventListener('pointermove', onCarouselDocMove)
  document.removeEventListener('pointerup', onCarouselDocUp)
  document.removeEventListener('pointercancel', onCarouselDocUp)
  if (isDraggingCarousel.value) {
    const threshold = carouselSlideStep.value * 0.25
    const cycleLen = carouselCycleLen.value
    const garages = carouselGarages.value
    const WRAP_ANIM_MS = 350
    if (carouselDragDelta.value < -threshold) {
      const next = carouselSlideIndex.value + 1
      const willWrap = cycleLen >= 2 && next >= 2 * cycleLen
      if (willWrap) {
        isDraggingCarousel.value = false
        carouselDragDelta.value = 0
        carouselTransitionDuration.value = 0.35
        carouselSlideIndex.value = next
        if (garages[next]) selectedGarage.value = garages[next]
        setTimeout(() => {
          isWrappingCarousel.value = true
          carouselSlideIndex.value = cycleLen
          nextTick(() => requestAnimationFrame(() => {
            isWrappingCarousel.value = false
          }))
        }, WRAP_ANIM_MS)
      } else {
        carouselSlideIndex.value = cycleLen >= 2 ? next : Math.min(next, garages.length - 1)
        if (garages[carouselSlideIndex.value]) selectedGarage.value = garages[carouselSlideIndex.value]
      }
    } else if (carouselDragDelta.value > threshold) {
      const prev = carouselSlideIndex.value - 1
      const willWrap = cycleLen >= 2 && prev < cycleLen
      if (willWrap) {
        isDraggingCarousel.value = false
        carouselDragDelta.value = 0
        carouselTransitionDuration.value = 0.35
        carouselSlideIndex.value = prev
        if (garages[prev]) selectedGarage.value = garages[prev]
        setTimeout(() => {
          isWrappingCarousel.value = true
          carouselSlideIndex.value = 2 * cycleLen - 1
          nextTick(() => requestAnimationFrame(() => {
            isWrappingCarousel.value = false
          }))
        }, WRAP_ANIM_MS)
      } else {
        carouselSlideIndex.value = cycleLen >= 2 ? prev : Math.max(0, prev)
        if (garages[carouselSlideIndex.value]) selectedGarage.value = garages[carouselSlideIndex.value]
      }
    }
    suppressCarouselClickUntil.value = Date.now() + 150
  }
  isDraggingCarousel.value = false
  carouselDragDelta.value = 0
}

function onCarouselViewportClick(event) {
  if (Date.now() < suppressCarouselClickUntil.value) return
  const viewport = carouselViewportRef.value
  if (!viewport) return
  const track = viewport.querySelector('.map-carousel-track')
  const rect = viewport.getBoundingClientRect()
  const trackPadding = track ? parseFloat(getComputedStyle(track).paddingLeft) || 0 : 0
  const x = event.clientX - rect.left - trackPadding - carouselOffset.value
  const step = carouselSlideStep.value
  if (step <= 0) return
  const idx = Math.floor(x / step)
  const garage = carouselGarages.value[Math.max(0, Math.min(idx, carouselGarages.value.length - 1))]
  if (garage) focusGarage(garage, { centerMap: true, animateCenterMap: true })
}

function initCarouselScroll() {
  const list = filteredGarages.value
  if (list.length < 2) {
    carouselSlideIndex.value = 0
    return
  }
  carouselSlideIndex.value = carouselCycleLen.value
  if (selectedGarage.value) {
    const idx = list.findIndex(g => g.id === selectedGarage.value.id)
    if (idx >= 0) carouselSlideIndex.value = carouselCycleLen.value + idx
  }
}

function centerMapOnGarage(garage, animate = false) {
  if (!garage) return
  const posX = Number(garage.posX)
  const posY = Number(garage.posY)
  if (!Number.isFinite(posX) || !Number.isFinite(posY)) return
  const base = getMapBaseViewBox()
  const targetPanX = -posX - (base.x + base.w / 2)
  const targetPanY = posY - (base.y + base.h / 2)
  if (animate) {
    animateMapPanTo(targetPanX, targetPanY)
    return
  }
  stopMapFocusAnimation()
  panOffset.x = targetPanX
  panOffset.y = targetPanY
  applyEffectiveViewBox()
}

function focusGarage(garage, options = {}) {
  selectedGarage.value = garage
  scrollToGarageCard(garage.id)
  if (options.centerMap) centerMapOnGarage(garage, options.animateCenterMap)
}

function updateContainerSize() {
  if (!mapContainer.value) return
  const r = mapContainer.value.getBoundingClientRect()
  if (r.width > 0 && r.height > 0) {
    mapContainerSize.value = { width: r.width, height: r.height }
  }
}

function updateCarouselWidth() {
  const el = carouselViewportRef.value
  if (el) {
    const w = el.getBoundingClientRect().width
    if (w > 0) carouselWidth.value = w
  }
}

function initMap() {
  if (!mapContainer.value) return
  const terrainLayer = mapContainer.value.querySelector('.terrain-layer')
  const roadsLayer = mapContainer.value.querySelector('.roads-layer')
  const vehicleLayer = mapContainer.value.querySelector('.vehicle-layer')
  if (vehicleLayer) {
    if (terrainLayer) {
      if (!minimapStore.showTerrainImage) {
        const images = Array.from(minimapStore.svgLayers.terrain.children).filter(child => child.tagName === 'image')
        images.forEach(img => minimapStore.svgLayers.terrain.removeChild(img))
      }
      terrainLayer.appendChild(minimapStore.svgLayers.terrain)
    }
    if (roadsLayer) roadsLayer.appendChild(minimapStore.svgLayers.roads)
    vehicleLayer.appendChild(minimapStore.svgLayers.vehicles)
    updateContainerSize()
    applyEffectiveViewBox()
    updateCarouselWidth()
    if (typeof ResizeObserver !== 'undefined') {
      resizeObserver?.disconnect()
      resizeObserver = new ResizeObserver(() => updateContainerSize())
      resizeObserver.observe(mapContainer.value)
      carouselResizeObserver?.disconnect()
      carouselResizeObserver = new ResizeObserver(() => updateCarouselWidth())
      nextTick(() => {
        if (carouselViewportRef.value) carouselResizeObserver.observe(carouselViewportRef.value)
      })
    }
  }
}

async function mountMapIfVisible() {
  if (viewMode.value !== 'map' || !careerActive.value || !loaded.value) return
  await nextTick()
  initMap()
}

watch([viewMode, careerActive, loaded], async ([newViewMode], [oldViewMode]) => {
  let shouldCenterNearestOnOpen = false
  if (viewMode.value !== 'map') {
    selectedGarage.value = null
    minimapStore.viewControlledBy = null
    minimapStore.showTerrainImage = true
  } else {
    filterOpen.value = false
    sortOpen.value = false
    if (oldViewMode !== 'map') {
      realEstateBaseViewBox.value = buildWalkingZoomBaseViewBox()
    }
    minimapStore.viewControlledBy = 'realEstate'
    minimapStore.showTerrainImage = false
    if (oldViewMode !== 'map') {
      const nearest = getNearestGarage(filteredGarages.value)
      if (nearest) {
        selectedGarage.value = nearest
        shouldCenterNearestOnOpen = true
      }
    }
  }
  await mountMapIfVisible()
  nextTick(() => {
    initCarouselScroll()
    if (newViewMode === 'map' && shouldCenterNearestOnOpen && selectedGarage.value) {
      focusGarage(selectedGarage.value, { centerMap: true, animateCenterMap: true })
    }
  })
}, { immediate: true })

watch(viewMode, (mode) => {
  if (mode === 'mortgages') {
    refreshMortgages()
    return
  }
  if (mode !== 'listings') return
  refreshOwnedListings()
  if (listingsSubView.value === 'offers' && !selectedOwnedGarage.value) {
    listingsSubView.value = 'owned'
  }
})

watch(filterOpen, (open) => {
  if (open) {
    nextTick(() => {
      filterPanelRef.value?.focus()
      firstFilterInputRef.value?.focus()
    })
  }
})

watch(() => minimapStore.viewBox, () => {
  if (minimapStore.viewControlledBy === 'realEstate') return
  applyEffectiveViewBox()
})

watch(filteredGarages, (list) => {
  if (viewMode.value !== 'map') return
  if (!list.length) {
    selectedGarage.value = null
    return
  }
  const shouldAutoSelectNearest = !selectedGarage.value || !list.find(g => g.id === selectedGarage.value.id)
  if (shouldAutoSelectNearest) {
    selectedGarage.value = getNearestGarage(list)
  }
  nextTick(() => {
    initCarouselScroll()
    if (!selectedGarage.value) return
    if (shouldAutoSelectNearest) {
      focusGarage(selectedGarage.value, { centerMap: true, animateCenterMap: true })
    } else {
      scrollToGarageCard(selectedGarage.value.id)
    }
  })
})

watch(() => route.query.tab, (tab) => {
  if (tab === 'listings') {
    viewMode.value = 'listings'
    setListingsSubView('owned')
    refreshOwnedListings()
  }
}, { deep: true })

const handlePhoneRealEstateData = (data) => {
  failedImages.clear()
  garages.value = data.garages || []
  playerBalance.value = data.playerBalance ?? 0
  loaded.value = true
  if (viewMode.value === 'listings') {
    refreshOwnedListings()
  }
  mountMapIfVisible()
}

onMounted(async () => {
  minimapStore.init()
  events.on('phoneRealEstateData', handlePhoneRealEstateData)
  await lua.extensions.load('ui_phone_layout')
  careerActive.value = await lua.ui_phone_layout.getCareerActive()
  if (route.query?.tab === 'listings') {
    viewMode.value = 'listings'
    listingsSubView.value = 'owned'
  }
  if (careerActive.value) {
    await lua.extensions.load('ui_phone_realEstate')
    if (lua.ui_phone_realEstate?.requestGarageListings) {
      lua.ui_phone_realEstate.requestGarageListings()
    } else {
      loaded.value = true
    }
  } else {
    loaded.value = true
  }
  setTimeout(() => { if (!loaded.value) loaded.value = true }, 1000)

  await mountMapIfVisible()
})

onUnmounted(() => {
  events.off('phoneRealEstateData', handlePhoneRealEstateData)
  stopMapFocusAnimation()
  minimapStore.viewControlledBy = null
  minimapStore.showTerrainImage = true
  resizeObserver?.disconnect()
  resizeObserver = null
  carouselResizeObserver?.disconnect()
  carouselResizeObserver = null
  minimapStore.cleanup()
})
</script>

<style scoped lang="scss">
.re-app {
  height: 100%;
  position: relative;
  background: #111;
  color: white;
  overflow: hidden;
  border-radius: 0 0 16px 16px;
}

.empty-state {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(255,255,255,0.4);
  font-size: 14px;
  &.small { position: relative; inset: auto; font-size: 13px; padding: 40px 20px; flex: 0; }
}

/* ── TOOLBAR ── */
.toolbar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 1;
  padding: 44px 10px 8px;
  border-radius: 0 0 24px 24px;
  background: #111;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.view-toggle {
  display: flex;
  background: #1a1a1a;
  border-radius: 8px;
  padding: 2px;
  gap: 2px;

  button {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
    padding: 5px 10px;
    border: none;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    font-family: inherit;
    color: rgba(255,255,255,0.45);
    background: transparent;
    cursor: pointer;
    transition: all 0.15s ease;

    &.active {
      background: #2a2a2a;
      color: white;
    }
  }
}

.toolbar-row-2 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.dropdown-wrap {
  position: relative;
}

.dropdown-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 5px 10px;
  border-radius: 8px;
  border: 1px solid rgba(255,255,255,0.12);
  background: transparent;
  color: rgba(255,255,255,0.7);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  transition: all 0.15s ease;

  &.active {
    background: #f97316;
    border-color: #f97316;
    color: white;
  }
}

.dropdown-chevron {
  transition: transform 0.15s ease;
  &.open { transform: rotate(180deg); }
}

.dropdown-panel {
  position: absolute;
  top: 100%;
  left: 0;
  margin-top: 4px;
  z-index: 100;
  min-width: 220px;
  max-height: 70vh;
  overflow-y: auto;
  border-radius: 10px;
  border: 1px solid rgba(255,255,255,0.12);
  box-shadow: 0 8px 24px rgba(0,0,0,0.4);
  outline: none;

  &:focus {
    outline: none;
  }
}

.toolbar-count {
  margin-left: auto;
  font-size: 10px;
  color: rgba(255,255,255,0.4);
}

/* ── LIST VIEW ── */
.list-view {
  position: absolute;
  inset: 0;
  overflow-y: auto;
  padding: 130px 10px 80px;
  display: flex;
  flex-direction: column;
  gap: 8px;

  &::-webkit-scrollbar { width: 3px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 2px; }
}

.listings-view {
  position: absolute;
  inset: 0;
  overflow-y: auto;
  padding: 96px 10px 80px;
  display: flex;
  flex-direction: column;
  gap: 10px;

  &::-webkit-scrollbar { width: 3px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 2px; }
}

.listings-back-bar {
  display: block;
  width: 100%;
  padding: 8px 0;
  border: none;
  background: transparent;
  color: rgba(255,255,255,0.6);
  font-size: 12px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  text-align: left;

  &:hover { color: white; }
}

.listings-card {
  background: #1a1a1a;
  border-radius: 16px;
  border: 1px solid rgba(255,255,255,0.05);
}

.listings-card-img {
  position: relative;
  width: 100%;
  height: 150px;
  background: #0d0d0d;
  overflow: hidden;
  border-radius: 16px 16px 0 0;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.listings-card-price {
  position: absolute;
  bottom: 10px;
  left: 12px;
  font-size: 18px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.badge.listed {
  background: rgba(249, 115, 22, 0.85);
  color: white;
}

.badge.starter {
  background: rgba(255,255,255,0.15);
  color: rgba(255,255,255,0.7);
}

.listings-card-body {
  padding: 10px 14px;
}

.listings-card-info {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.listings-name {
  font-size: 14px;
  font-weight: 600;
}

.listings-card-meta {
  display: flex;
  align-items: center;
  gap: 14px;
  flex-wrap: wrap;
}

.listings-meta {
  color: rgba(255,255,255,0.6);
  font-size: 11px;
}

.listing-active {
  color: #34d399 !important;
}

.offer-count {
  color: #f97316 !important;
}

.listings-actions {
  padding: 0 14px 14px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.listing-price-row {
  display: flex;
  gap: 6px;
}

.listing-price-input {
  flex: 1;
  min-width: 0;
  padding: 8px 10px;
  border-radius: 10px;
  border: 1px solid rgba(255,255,255,0.12);
  background: #0d0d0d;
  color: #fff;
  font-size: 12px;
  font-family: inherit;
}

.listings-full-btn {
  width: 100%;
  justify-content: center;
}

.listing-guidance {
  margin: 0;
  font-size: 11px;
  line-height: 1.3;
  padding: 8px 10px;
  border-radius: 10px;
  background: #101010;
  border: 1px solid rgba(255,255,255,0.08);
}

.guidance-high { color: #34d399; }
.guidance-fair { color: #f97316; }
.guidance-low { color: #ef4444; }

.listings-listed-row {
  display: flex;
  gap: 8px;

  .act-btn { flex: 1; justify-content: center; }
}

.offer-actions-row,
.offer-actions {
  display: flex;
  gap: 8px;

  .act-btn { flex: 1; justify-content: center; }
}

.offer-shell {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.listings-offers-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  background: #1a1a1a;
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid rgba(255,255,255,0.05);
}

.offers-header-info {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.offers-count-badge {
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 50%;
  background: #f97316;
  color: white;
  font-size: 12px;
  font-weight: 700;
}

.offers-card {
  background: #1a1a1a;
  border-radius: 14px;
  border: 1px solid rgba(255,255,255,0.05);
  padding: 12px 14px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.offer-head {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  align-items: center;
}

.offer-buyer {
  font-size: 14px;
  font-weight: 600;
}

.offer-status {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.6px;
  padding: 3px 10px;
  border-radius: 999px;
  border: 1px solid rgba(255,255,255,0.2);
}

.status-open { color: #f97316; border-color: rgba(249,115,22,0.45); }
.status-closed { color: rgba(255,255,255,0.45); border-color: rgba(255,255,255,0.2); }

.offer-price {
  display: flex;
  justify-content: space-between;
  align-items: center;
  color: rgba(255,255,255,0.9);
  font-size: 13px;
  gap: 8px;
  padding: 6px 0;
  border-top: 1px solid rgba(255,255,255,0.06);

  .price-label { color: rgba(255,255,255,0.5); }

  s { color: rgba(255,255,255,0.35); margin-right: 6px; }
  strong { color: #34d399; }
}

.filter-panel,
.sort-panel {
  padding: 14px;
  background: #1a1a1a;
  border-radius: 12px;
  border: 1px solid rgba(255,255,255,0.12);
  box-shadow: 0 8px 32px rgba(0,0,0,0.5);
}

.filter-panel {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0,0,0,0);
  border: 0;
}

.custom-checkbox {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  border-radius: 50%;
  border: 1.5px solid rgba(255,255,255,0.35);
  flex-shrink: 0;
  cursor: pointer;
  transition: border-color 0.15s ease;

  .custom-checkbox-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #f97316;
    opacity: 0;
    transform: scale(0.5);
    transition: opacity 0.15s ease, transform 0.15s ease;
  }

  &.checked .custom-checkbox-dot {
    opacity: 1;
    transform: scale(1);
  }

  &.checked { border-color: rgba(249,115,22,0.5); }
}

.filter-opt {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: rgba(255,255,255,0.8);
  cursor: pointer;
}

.filter-row {
  display: grid;
  grid-template-columns: 52px 1fr;
  gap: 6px;
  align-items: start;

  > label {
    font-size: 11px;
    color: rgba(255,255,255,0.5);
    padding-top: 6px;
  }
}

.filter-inputs-stacked {
  display: flex;
  flex-direction: column;
  gap: 4px;

  input {
    width: 100%;
    padding: 6px 8px;
    border-radius: 6px;
    border: 1px solid rgba(255,255,255,0.15);
    background: #0d0d0d;
    color: white;
    font-size: 12px;
    font-family: inherit;
    box-sizing: border-box;

    &::placeholder {
      color: rgba(255,255,255,0.3);
    }

    &[type="number"] {
      -moz-appearance: textfield;
      appearance: textfield;

      &::-webkit-inner-spin-button,
      &::-webkit-outer-spin-button {
        -webkit-appearance: none;
        appearance: none;
        margin: 0;
      }
    }
  }
}

.filter-clear {
  padding: 6px 12px;
  border-radius: 8px;
  border: 1px solid rgba(255,255,255,0.2);
  background: transparent;
  color: rgba(255,255,255,0.6);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  align-self: flex-start;
}

.sort-panel {
  min-width: 200px;
}

.sort-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 6px 12px;
  align-items: center;
}

.sort-label {
  font-size: 11px;
  color: rgba(255,255,255,0.5);
}

.sort-options {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 4px;
}

.sort-options:last-of-type {
  grid-template-columns: repeat(2, 1fr);
}

.sort-opt {
  padding: 5px 10px;
  border-radius: 8px;
  border: 1px solid rgba(255,255,255,0.12);
  background: transparent;
  color: rgba(255,255,255,0.7);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  transition: all 0.15s ease;

  &.active {
    background: #f97316;
    border-color: #f97316;
    color: white;
  }
}

.card {
  flex-shrink: 0;
  min-height: 200px;
  background: #1a1a1a;
  border-radius: 16px;
  overflow: hidden;
  cursor: pointer;
  border: 1px solid rgba(255,255,255,0.05);
  transition: border-color 0.15s ease;

  &.owned { border-color: rgba(249,115,22,0.2); }
  &:active { background: #1e1e1e; }
}

.card-img {
  position: relative;
  width: 100%;
  height: 160px;
  flex-shrink: 0;
  background: #0d0d0d;
  overflow: hidden;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.card-img-ph {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  background: linear-gradient(135deg, #1a1a1a, #0d0d0d);

  span {
    font-size: 10px;
    color: rgba(255,255,255,0.18);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }

  &.small {
    height: 80px;
    span { display: none; }
  }
}

.card-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(0,0,0,0.65) 0%, transparent 50%);
  pointer-events: none;
}

.card-badges {
  position: absolute;
  top: 8px;
  left: 10px;
  display: flex;
  gap: 4px;
}

.badge {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 6px;
  letter-spacing: 0.5px;

  &.owned { background: #f97316; color: white; }
  &.free { background: #22c55e; color: white; }
}

.card-price {
  position: absolute;
  bottom: 10px;
  left: 12px;
  font-size: 18px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.card-body {
  display: flex;
  align-items: center;
  padding: 10px 14px;
  gap: 8px;
}

.card-info { flex: 1; min-width: 0; }

.card-name {
  font-size: 14px;
  font-weight: 600;
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.card-meta {
  display: flex;
  align-items: center;
  gap: 14px;
  margin-top: 3px;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  color: rgba(255,255,255,0.45);
}

.chevron {
  flex-shrink: 0;
  transition: transform 0.2s ease;
  &.open { transform: rotate(180deg); }
}

.card-expand {
  padding: 0 14px 14px;
  animation: slideDown 0.2s ease;
}

.card-desc {
  font-size: 12px;
  color: rgba(255,255,255,0.35);
  margin: 0 0 10px;
  line-height: 1.4;
}

.card-actions, .map-card-actions {
  display: flex;
  gap: 8px;
}

.act-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 8px 14px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.15s ease;
  &:hover { opacity: 0.85; }

  &.route { background: rgba(249,115,22,0.15); color: #f97316; }
  &.negotiate { background: #f97316; color: white; }
  &.decline { background: rgba(239,68,68,0.15); color: #ef4444; }

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

/* ── MAP VIEW ── */
.map-view {
  position: absolute;
  inset: 0;
  overflow: hidden;
}

.map-layers {
  position: absolute;
  inset: 0;
  background: rgba(30,30,30,0.95);
  touch-action: none;
}

.map-layer {
  position: absolute;
  width: 100%;
  height: 100%;
  pointer-events: none;
}

.marker-layer {
  pointer-events: all;
}

.garage-marker {
  cursor: pointer;

  .marker-bg {
    fill: rgba(0,0,0,0.5);
    stroke: none;
    transition: all 0.15s ease;
  }

  .marker-dot {
    fill: #f97316;
    stroke: white;
    stroke-width: 1.5;
    transition: all 0.15s ease;

    &.owned { fill: #22c55e; }
  }

  .marker-label {
    fill: white;
    font-size: 14px;
    font-weight: 700;
    paint-order: stroke;
    stroke: rgba(0,0,0,0.8);
    stroke-width: 4px;
  }

  .marker-count {
    font-size: 16px;
  }

  &.selected {
    .marker-bg {
      fill: rgba(249,115,22,0.3);
      r: 24;
    }
    .marker-dot {
      stroke: #f97316;
      stroke-width: 2.5;
    }
  }
}

/* ── MAP CAROUSEL ── */
.map-carousel-wrap {
  position: absolute;
  bottom: 10px;
  left: 0;
  right: 0;
  z-index: 5;
  pointer-events: auto;
}

.map-carousel-viewport {
  overflow: hidden;
  padding: 0 0 30px;
  cursor: grab;
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;

  &:active { cursor: grabbing; }
}

.map-carousel-track {
  display: flex;
  gap: 10px;
  padding-left: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  padding-right: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  transition: transform var(--carousel-duration, 0.35s) cubic-bezier(0.25, 0.46, 0.45, 0.94);

  &.no-transition { transition: none; }
}

.map-slide {
  flex-shrink: 0;
  pointer-events: none;
  background: rgba(24, 24, 24, 0.96);
  border-radius: 18px;
  overflow: hidden;
  border: 1px solid rgba(255,255,255,0.08);
  box-shadow: 0 8px 20px rgba(0,0,0,0.45);
  pointer-events: auto;

  &.selected {
    border-color: rgba(249,115,22,0.6);
  }

  .act-btn {
    pointer-events: auto;
  }
}

.map-slide-img {
  position: relative;
  width: 100%;
  height: 118px;
  background: #0d0d0d;
  overflow: hidden;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.map-slide-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(0,0,0,0.65) 0%, transparent 50%);
  pointer-events: none;
}

.map-slide-badges {
  position: absolute;
  top: 6px;
  left: 8px;
  display: flex;
  gap: 4px;
}

.map-slide-price-overlay {
  position: absolute;
  bottom: 8px;
  left: 10px;
  font-size: 15px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.map-slide-body {
  padding: 10px 12px 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.map-slide-top {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.map-slide-name {
  font-size: 14px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
  min-width: 0;
}

.map-slide-price {
  font-size: 15px;
  font-weight: 700;
  color: #f97316;
  white-space: nowrap;
}

.map-slide-owned {
  font-size: 10px;
  font-weight: 700;
  background: #f97316;
  color: white;
  padding: 2px 7px;
  border-radius: 5px;
  white-space: nowrap;
}

.map-slide-meta-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.map-slide-meta {
  display: flex;
  gap: 12px;

  span {
    display: flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    color: rgba(255,255,255,0.4);
  }
}

.map-slide-meta-row .act-btn {
  flex-shrink: 0;
  padding: 6px 12px;
  font-size: 11px;
}

/* ── MORTGAGES VIEW ── */
.mortgage-card {
  background: #1a1a1a;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.05);
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 10px;

  &.mortgage-ok { border-left: 3px solid #22c55e; }
  &.mortgage-warning { border-left: 3px solid #eab308; }
  &.mortgage-danger { border-left: 3px solid #ef4444; }
}

.mortgage-card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.mortgage-card-info {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.mortgage-prop-name {
  font-size: 14px;
  font-weight: 600;
}

.mortgage-card-meta {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.45);
}

.mortgage-strike-dots {
  display: flex;
  gap: 4px;
}

.strike-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #ef4444;
}

.mortgage-card-body {
  display: flex;
  gap: 12px;
}

.mortgage-stat {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
  background: rgba(255, 255, 255, 0.03);
  border-radius: 8px;
  padding: 8px 10px;
}

.mortgage-stat-label {
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: rgba(255, 255, 255, 0.35);
  font-weight: 700;
}

.mortgage-stat-val {
  font-size: 13px;
  font-weight: 700;
  color: white;
  font-variant-numeric: tabular-nums;
}

.mortgage-card-warning {
  font-size: 11px;
  padding: 8px 10px;
  border-radius: 8px;
  background: rgba(234, 179, 8, 0.1);
  color: rgba(234, 179, 8, 0.9);

  &.danger {
    background: rgba(239, 68, 68, 0.1);
    color: rgba(239, 68, 68, 0.9);
  }
}

.mortgage-card-actions {
  display: flex;
  gap: 8px;

  .act-btn { flex: 1; justify-content: center; }
}

/* ── TRANSITIONS ── */
@keyframes slideDown {
  from { opacity: 0; transform: translateY(-6px); }
  to { opacity: 1; transform: translateY(0); }
}
</style>
