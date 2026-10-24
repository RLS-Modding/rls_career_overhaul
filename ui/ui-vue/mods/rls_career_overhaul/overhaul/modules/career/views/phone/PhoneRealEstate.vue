<!--
Map of PhoneRealEstate.vue. This view owns lifecycle, the tab state and the minimap claim.
- Script, in reading order: refs and tab state; filters (usePhoneRealEstateFilters); owned
  listings and offers (usePhoneRealEstateListings); map pan, zoom and animation (usePhoneMapView);
  carousel; end-lease dialog state; map centering and sizing; watchers; mount and unmount.
- Child in phoneRealEstate/: the owned listing card. It takes props and emits events, and never
  calls the bridge or reads the tab state.
- Styles: inline below; the rules shared by the list cards, offers panel and owned cards are in the src overlay phoneRealEstate/_shared.scss.
-->
<template>
  <div class="re-app" ref="screenRef" v-bng-ui-nav-scroll v-bng-on-ui-nav:tab_l="() => changeView(-1)" v-bng-on-ui-nav:tab_r="() => changeView(1)" v-bng-on-ui-nav:subtab_l="viewMode === 'map' ? () => nextProperty(-1) : undefined" v-bng-on-ui-nav:subtab_r="viewMode === 'map' ? () => nextProperty(1) : undefined">
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
        </div>
        <div v-if="viewMode === 'list'" class="toolbar-row-2">
          <div class="dropdown-wrap">
            <button class="dropdown-btn" :class="{ active: filterOpen }" @click="filterOpen = !filterOpen; sortOpen = false">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>
              Filter
              <svg class="dropdown-chevron" :class="{ open: filterOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
            </button>
            <PhoneLayer v-if="filterOpen" class="dropdown-panel filter-panel" ref="filterPanelRef" tabindex="-1" @mousedown.stop label="Property filters" @close="filterOpen = false">
              <label class="filter-opt" role="checkbox" tabindex="0" bng-nav-item :aria-checked="filterForm.affordable">
                <span class="custom-checkbox" :class="{ checked: filterForm.affordable }"><span class="custom-checkbox-dot"></span></span>
                <input type="checkbox" v-model="filterForm.affordable" class="sr-only"  bng-no-nav="true"/>
                Affordable only
              </label>
              <label class="filter-opt" role="checkbox" tabindex="0" bng-nav-item :aria-checked="filterForm.notOwned">
                <span class="custom-checkbox" :class="{ checked: filterForm.notOwned }"><span class="custom-checkbox-dot"></span></span>
                <input type="checkbox" v-model="filterForm.notOwned" class="sr-only"  bng-no-nav="true"/>
                Not Owned
              </label>
              <div class="filter-row">
                <label>Price</label>
                <div class="filter-inputs-stacked">
                  <input ref="firstFilterInputRef" type="number" v-model.number="filterForm.priceMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="10000"/>
                  <input type="number" v-model.number="filterForm.priceMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="10000"/>
                </div>
              </div>
              <div class="filter-row">
                <label>Slots</label>
                <div class="filter-inputs-stacked">
                  <input type="number" v-model.number="filterForm.slotsMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="1"/>
                  <input type="number" v-model.number="filterForm.slotsMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="1"/>
                </div>
              </div>
              <div class="filter-row">
                <label>Dist (m)</label>
                <div class="filter-inputs-stacked">
                  <input type="number" v-model.number="filterForm.distMin" placeholder="Min" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="100"/>
                  <input type="number" v-model.number="filterForm.distMax" placeholder="Max" min="0" inputmode="numeric" v-bng-text-input  v-phone-number="100"/>
                </div>
              </div>
              <button class="filter-clear" @click="clearFilters">Clear</button>
            </PhoneLayer>
          </div>
          <div class="dropdown-wrap">
            <button class="dropdown-btn" :class="{ active: sortOpen }" @click="sortOpen = !sortOpen; filterOpen = false">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="14" y2="12"/><line x1="4" y1="18" x2="9" y2="18"/></svg>
              Sort
              <svg class="dropdown-chevron" :class="{ open: sortOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
            </button>
            <PhoneLayer v-if="sortOpen" class="dropdown-panel sort-panel" label="Property sorting" @close="sortOpen = false">
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
            </PhoneLayer>
          </div>
          <span class="toolbar-count">{{ listFilteredGarages.length }} shown</span>
        </div>
      </div>

      <!-- LIST VIEW -->
      <div class="list-view" v-if="viewMode === 'list'" v-bng-ui-nav-scroll>
        <div v-if="listFilteredGarages.length === 0" class="empty-state small">No properties match filters.</div>
        <div
          v-for="garage in listFilteredGarages"
          :key="garage.id"
          class="card"
          :class="{ owned: garage.owned }"
          @click="toggleExpand(garage.id)"
         role="button" tabindex="0" bng-nav-item :data-fk="garage.id" :aria-expanded="expandedId === garage.id">
          <div class="card-img">
            <img v-if="garage.preview && !imgFailed(garage.id)" :src="garage.preview" alt="" @error="onImgError(garage)" />
            <div v-else class="card-img-ph">
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>
              <span>No preview</span>
            </div>
            <div class="card-img-fade"></div>
            <div class="card-badges">
              <span v-if="garage.owned" class="badge owned">OWNED</span>
              <span v-else-if="garage.rented" class="badge rented">RENTED</span>
              <span v-else-if="garage.canReclaim" class="badge free">RECLAIM</span>
              <span v-else-if="garage.starterGarage" class="badge free">FREE</span>
            </div>
            <div class="card-price" v-if="!garage.owned && !garage.rented">{{ (garage.canReclaim || garage.starterGarage) ? 'FREE' : '$' + formatPrice(garage.price) }}</div>
          </div>
          <div class="card-body">
            <div class="card-info">
              <span class="card-name">{{ garage.name }}</span>
              <div class="card-meta">
                <span class="meta-item">
                  <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="1" y="3" width="15" height="13" rx="2"/><path d="M16 8h2a2 2 0 012 2v6a2 2 0 01-2 2H6"/><circle cx="5.5" cy="18.5" r="2.5"/><circle cx="18.5" cy="18.5" r="2.5"/></svg>
                  <template v-if="garage.owned">{{ garage.vehicleCount }}/{{ garage.capacity }}</template>
                  <template v-else>{{ garage.capacity }} {{ garage.capacity === 1 ? 'slot' : 'slots' }}</template>
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
              <template v-if="garage.canReclaim">
                <button class="act-btn negotiate" @click.stop="confirmReclaim(garage)">
                  Reclaim Free
                </button>
              </template>
              <template v-else-if="garage.rented">
                <button class="act-btn danger" @click.stop="endLease(garage)">
                  End Lease Early
                </button>
              </template>
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
          <svg class="map-layer marker-layer" :viewBox="markerViewBox">
            <g v-for="item in clusteredMarkers" :key="'m-'+item.cluster[0].id"
              :transform="'translate(' + (-item.posX) + ',' + item.posY + ') scale(' + zoomFactor + ')'"
              class="garage-marker"
              :class="{ selected: selectedGarage && item.cluster.some(g => g.id === selectedGarage.id), cluster: item.count > 1 }"
              role="button" tabindex="0" bng-nav-item
              @click.stop="selectMarker(item.cluster[0])"
            >
              <circle r="18" class="marker-bg" />
              <circle r="12" class="marker-dot" :class="{ owned: item.count === 1 && item.cluster[0].owned }" />
              <template v-if="item.count > 1">
                <text y="0" text-anchor="middle" dominant-baseline="middle" class="marker-label marker-count">{{ item.count }}</text>
              </template>
              <template v-else>
                <svg x="-7.5" y="-7.5" width="15" height="15" viewBox="0 0 24 24" fill="white" stroke="none"><path d="M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>
                <text y="28" text-anchor="middle" class="marker-label">{{ item.cluster[0].owned ? 'OWNED' : (item.cluster[0].canReclaim ? 'RECLAIM' : (item.cluster[0].starterGarage ? 'FREE' : '$' + formatPrice(item.cluster[0].price))) }}</text>
              </template>
            </g>
          </svg>
        </div>

        <div class="map-carousel-wrap">
          <div
            class="map-carousel-viewport" role="slider" tabindex="0" bng-nav-item
            aria-label="Property selection" aria-valuemin="1" :aria-valuemax="garages.length"
            :aria-valuenow="Math.max(0, garages.findIndex(g => g.id === selectedGarage?.id)) + 1"
            :aria-valuetext="selectedGarage?.name"
            v-bng-on-ui-nav:focus_l.focusRequired="() => nextProperty(-1)"
            v-bng-on-ui-nav:focus_r.focusRequired="() => nextProperty(1)"
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
                class="map-slide" :inert="selectedGarage?.id !== garage.id"
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
                  <span v-else-if="garage.rented" class="badge rented">RENTED</span>
                  <span v-else-if="garage.canReclaim" class="badge free">RECLAIM</span>
                  <span v-else-if="garage.starterGarage" class="badge free">FREE</span>
                </div>
                <div class="map-slide-price-overlay" v-if="!garage.owned && !garage.rented">{{ (garage.canReclaim || garage.starterGarage) ? 'FREE' : '$' + formatPrice(garage.price) }}</div>
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
                      <template v-else>{{ garage.capacity }} {{ garage.capacity === 1 ? 'slot' : 'slots' }}</template>
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
                  <button v-if="garage.canReclaim" class="act-btn negotiate" @click.stop="confirmReclaim(garage)">
                    Reclaim
                  </button>
                </div>
              </div>
              </article>
            </div>
          </div>
        </div>
      </div>

      <!-- LISTINGS VIEW -->
      <div class="listings-view" v-if="viewMode === 'listings'" v-bng-ui-nav-scroll>
        <button v-if="listingsSubView === 'offers'" class="listings-back-bar" @click="setListingsSubView('owned')">
          &larr; Back to properties
        </button>

        <template v-if="listingsSubView === 'owned'">
          <div v-if="ownedListings.length === 0" class="empty-state small">No properties owned.</div>
          <RealEstateOwnedListingCard
            v-for="garage in ownedListings"
            :key="garage.garageId"
            :garage="garage"
            :image-failed="imgFailed(garage.garageId)"
            :price="listingPrices[garage.garageId]"
            :guidance="listingGuidance[garage.garageId]"
            @image-error="onImgError({ id: garage.garageId })"
            @update:price="listingPrices[garage.garageId] = $event"
            @check-price="getGuidance(garage)"
            @list-for-sale="listGarageForSale(garage)"
            @move-out="confirmMoveOut(garage)"
            @reclaim="confirmReclaimOwned(garage)"
            @view-offers="openOwnedOffers(garage)"
            @remove-listing="removeOwnedListing(garage)"
          />
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

    <Transition name="modal-fade">
      <PhoneLayer v-if="showEndLeaseConfirm && endLeaseTarget" class="end-lease-overlay" @click.self="showEndLeaseConfirm = false" label="End lease" @close="showEndLeaseConfirm = false">
        <div class="end-lease-modal">
          <p class="end-lease-title">End Lease Early?</p>
          <p class="end-lease-property">{{ endLeaseTarget.name }}</p>
          <div class="end-lease-fees">
            <div class="fee-row">
              <span>Deposit forfeited</span>
              <span class="fee-val">${{ formatPrice(endLeaseTarget.securityDeposit) }}</span>
            </div>
            <div class="fee-row">
              <span>Termination fee</span>
              <span class="fee-val">${{ formatPrice(endLeaseTarget.monthlyRent) }}</span>
            </div>
            <div class="fee-divider"></div>
            <div class="fee-row total">
              <span>Total cost</span>
              <span class="fee-val">${{ formatPrice(endLeaseTarget.securityDeposit + endLeaseTarget.monthlyRent) }}</span>
            </div>
          </div>
          <p class="end-lease-note">Vehicles in this garage will be relocated.</p>
          <div class="end-lease-actions">
            <button class="modal-btn cancel-btn" @click="showEndLeaseConfirm = false" bng-scoped-nav-autofocus>Cancel</button>
            <button class="modal-btn confirm-btn" @click="confirmEndLease">End Lease</button>
          </div>
        </div>
      </PhoneLayer></Transition>
  </div>
</template>

<script setup>
import { vPhoneNumber } from "../../components/phone/phoneNumber.js"
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import { usePhoneViewFocus } from '../../components/phone/usePhoneViewFocus.js'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import PhoneLayer from '../../components/phone/PhoneLayer.vue'
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { useRoute } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { openConfirmation } from '@/services/popup'
import { useMinimapStore } from '../../stores/minimapStore'
import { vBngTextInput } from '@/common/directives'
import { acquireScope } from '../../utils/luaScopes'
import { usePhoneCarousel } from '../../composables/usePhoneCarousel'
import { usePhoneMapView, clusterPhoneMapItems } from '../../composables/usePhoneMapView'
import { usePhoneRealEstateFilters } from '../../composables/usePhoneRealEstateFilters'
import { usePhoneRealEstateListings } from '../../composables/usePhoneRealEstateListings'
import { safeLua } from '../../utils/safeLua'
import RealEstateOwnedListingCard from '../phoneRealEstate/RealEstateOwnedListingCard.vue'
import { formatPrice, formatDistance, cleanDescription } from '../phoneRealEstate/realEstateFormat'

defineOptions({ directives: { BngTextInput: vBngTextInput } })

const events = useEvents()
const minimapStore = useMinimapStore()
const route = useRoute()

// Shows the screen when the data reply is slow; a late reply still fills it in.
const LOADED_FALLBACK_MS = 1000

const garages = ref([])
const playerBalance = ref(0)
const careerActive = ref(true)
const loaded = ref(false)

const filterOpen = ref(false)
const sortOpen = ref(false)
const { filterForm, sortBy, sortAsc, sortFields, listFilteredGarages, clearFilters } = usePhoneRealEstateFilters({ garages, playerBalance })
const failedImages = reactive(new Set())

const viewMode = ref('map')
const {
  listingsSubView, ownedListings, listingPrices, listingGuidance, selectedOwnedGarage, selectedOwnedOffers,
  defaultListingPrice, refreshOwnedListings, setListingsSubView, openOwnedOffers, getGuidance, listGarageForSale,
  confirmMoveOut, confirmReclaim, confirmReclaimOwned, removeOwnedListing, acceptOwnedOffer, declineOwnedOffer,
  negotiateOwnedOffer,
} = usePhoneRealEstateListings({ lua, openConfirmation })
const expandedId = ref(null)
const selectedGarage = ref(null)
const showEndLeaseConfirm = ref(false)
const endLeaseTarget = ref(null)
const filterPanelRef = ref(null)
const firstFilterInputRef = ref(null)
const screenRef = ref(null)
usePhoneScreen({ onBack: () => {
  if (listingsSubView.value === 'offers') { setListingsSubView('owned'); return true }
  if (expandedId.value) { expandedId.value = null; return true }
  return false
} })
usePhoneViewFocus(screenRef, () => `${viewMode.value}:${listingsSubView.value}`)
function changeView(delta) {
  if (filterOpen.value || sortOpen.value || showEndLeaseConfirm.value) return
  const views = ['list', 'map', 'listings']
  viewMode.value = views[(views.indexOf(viewMode.value) + delta + views.length) % views.length]
}
function nextProperty(delta) {
  const list = garages.value
  if (!list.length) return
  const current = list.findIndex(g => g.id === selectedGarage.value?.id)
  const index = (Math.max(0, current) + delta + list.length) % list.length
  focusGarage(list[index], { centerMap: true, animateCenterMap: true })
}

let resizeObserver = null
let carouselResizeObserver = null

// The minimap is shared, so the map view owns only its own pan, zoom and animation state.
const {
  mapContainer, markerViewBox, baseViewBox: realEstateBaseViewBox, panOffset, zoomFactor, panState,
  suppressMarkerClickUntil, parseViewBox, buildWalkingZoomBaseViewBox, getMapBaseViewBox, applyEffectiveViewBox,
  stopMapFocusAnimation, animateMapPanTo, onMapWheel, onMapPointerDown, onMapPointerMove, onMapPointerUp,
} = usePhoneMapView({ minimapStore, ownerId: 'realEstate' })

// Use layout width (not getBoundingClientRect) so phone CSS scale doesn't inflate slides past the viewport.
const CAROUSEL_SIDE_INSET = 14
const carouselViewportRef = ref(null)
const carouselWidth = ref(340)
const carouselSlideWidth = computed(() => Math.max(0, carouselWidth.value - CAROUSEL_SIDE_INSET * 2))
const carousel = usePhoneCarousel({
  items: garages,
  slideWidth: carouselSlideWidth,
  viewportRef: carouselViewportRef,
  onSelect: garage => { selectedGarage.value = garage },
})
const {
  slides: carouselGarages,
  slideOffset: carouselOffset,
  transitionDuration: carouselTransitionDuration,
  isDragging: isDraggingCarousel,
  isWrapping: isWrappingCarousel,
} = carousel
const onCarouselPointerDown = carousel.onPointerDown

// Markers closer than this on screen merge into one cluster.
const CLUSTER_RADIUS_PX = 50
const mapContainerSize = ref({ width: 400, height: 400 })

function clusterGarages(list, viewBoxStr, containerSize) {
  return clusterPhoneMapItems(list, viewBoxStr, containerSize, {
    keyOf: garage => garage.id,
    xOf: garage => garage.posX,
    yOf: garage => garage.posY,
    radiusPx: CLUSTER_RADIUS_PX,
  })
}

const clusteredMarkers = computed(() =>
  clusterGarages(garages.value, markerViewBox.value, mapContainerSize.value)
)

// A failed lookup leaves the dialog closed. safeLua logs the failure once per context.
const endLease = garage => safeLua(async () => {
  const info = await lua.overhaul_career_garage_property_propertyRentals.getRentalInfo(garage.id)
  endLeaseTarget.value = {
    id: garage.id,
    name: garage.name,
    monthlyRent: info?.monthlyRent || 0,
    securityDeposit: info?.securityDeposit || 0,
  }
  showEndLeaseConfirm.value = true
}, 'Load rental terms for an early lease end')

// The reload runs only after the lease end succeeds.
const confirmEndLease = async () => {
  if (!endLeaseTarget.value) return
  const garageId = endLeaseTarget.value.id
  showEndLeaseConfirm.value = false
  endLeaseTarget.value = null
  await safeLua(async () => {
    await lua.overhaul_phone_apps_realEstate.endLeaseEarly(garageId)
    lua.overhaul_phone_apps_realEstate.requestGarageListings()
  }, 'End a lease early')
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

function toggleExpand(id) {
  expandedId.value = expandedId.value === id ? null : id
}

function selectMarker(garage) {
  if (Date.now() < suppressMarkerClickUntil.value) return
  focusGarage(garage, { centerMap: true, animateCenterMap: true })
}

function setRoute(garage) {
  lua.overhaul_phone_apps_realEstate.setRouteToGarage(garage.id)
}

function openGarageListing(garage) {
  if (garage?.id) lua.overhaul_career_garage_garageManager.showPurchaseGaragePrompt(garage.id)
}

function imgFailed(garageId) {
  return failedImages.has(garageId)
}

function onImgError(garage) {
  failedImages.add(garage.id)
}

const onGarageListingsUpdated = async () => {
  await refreshOwnedListings()
  if (lua.overhaul_phone_apps_realEstate?.requestGarageListings) {
    lua.overhaul_phone_apps_realEstate.requestGarageListings()
  }
}

function scrollToGarageCard(garageId) {
  if (!garageId) return
  const index = garages.value.findIndex(g => g.id === garageId)
  if (index < 0) return
  carousel.scrollToItem(index)
}

function onCarouselViewportClick(event) {
  const garage = carousel.itemAtClick(event)
  if (garage) focusGarage(garage, { centerMap: true, animateCenterMap: true })
}

function initCarouselScroll() {
  const list = garages.value
  const selectedIndex = selectedGarage.value ? list.findIndex(g => g.id === selectedGarage.value.id) : -1
  carousel.snapToItem(Math.max(0, selectedIndex))
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
    const w = el.clientWidth
    if (w > 0) carouselWidth.value = w
  }
}

let mapView = null

function initMap() {
  if (!mapContainer.value) return
  mapView?.dispose()
  const host = mapContainer.value.querySelector('.map-layers')
  if (host) {
    mapView = minimapStore.mountMap(host)
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
    mapView?.dispose()
    mapView = null
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
      const nearest = getNearestGarage(garages.value)
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
  if (mode !== 'listings') return
  refreshOwnedListings()
  if (listingsSubView.value === 'offers' && !selectedOwnedGarage.value) {
    listingsSubView.value = 'owned'
  }
})

watch(filterOpen, (open) => {
  if (open) {
    nextTick(() => {
      ;(filterPanelRef.value?.$el || filterPanelRef.value)?.focus?.()
      firstFilterInputRef.value?.focus()
    })
  }
})

watch(() => minimapStore.viewBox, () => {
  if (minimapStore.viewControlledBy === 'realEstate') return
  applyEffectiveViewBox()
})

watch(garages, (list) => {
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
  minimapStore.acquire()
  events.on('phoneRealEstateData', handlePhoneRealEstateData)
  events.on('garageListingsUpdated', onGarageListingsUpdated)
  await acquireScope(lua, 'phone.layout')
  careerActive.value = await lua.overhaul_phone_apps_layout.getCareerActive()
  const returnTab = sessionStorage.getItem('phoneRealEstateReturnTab')
  sessionStorage.removeItem('phoneRealEstateReturnTab')
  if (route.query?.tab === 'listings' || returnTab === 'listings') {
    viewMode.value = 'listings'
    listingsSubView.value = 'owned'
  }
  if (careerActive.value) {
    await acquireScope(lua, 'phone.realEstate')
    if (lua.overhaul_phone_apps_realEstate?.requestGarageListings) {
      lua.overhaul_phone_apps_realEstate.requestGarageListings()
    } else {
      loaded.value = true
    }
  } else {
    loaded.value = true
  }
  setTimeout(() => { if (!loaded.value) loaded.value = true }, LOADED_FALLBACK_MS)

  await mountMapIfVisible()
})

onUnmounted(() => {
  events.off('phoneRealEstateData', handlePhoneRealEstateData)
  events.off('garageListingsUpdated', onGarageListingsUpdated)
  stopMapFocusAnimation()
  minimapStore.viewControlledBy = null
  minimapStore.showTerrainImage = true
  resizeObserver?.disconnect()
  resizeObserver = null
  carouselResizeObserver?.disconnect()
  carouselResizeObserver = null
  mapView?.dispose()
  minimapStore.release()
})
</script>
<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/views/phoneRealEstate/shared";

// Page frame, toolbar, list and listings containers, and the modal fade transition. Owned by PhoneRealEstate.vue.

.re-app {
  height: 100%;
  position: relative;
  background: #111;
  color: white;
  overflow: hidden;
  border-radius: 0 0 16px 16px;
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

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;
}
.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
}
// Filter and sort dropdown panels. Owned by PhoneRealEstate.vue.

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
// Map layers, garage markers and the carousel of garage cards under the map. Owned by PhoneRealEstate.vue.

/* ── MAP VIEW ── */
.map-view {
  position: absolute;
  inset: 0;
  // Keep map layers below the sibling toolbar, including their hit targets.
  isolation: isolate;
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
  z-index: 1;
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
  transition: transform var(--carousel-duration) cubic-bezier(0.25, 0.46, 0.45, 0.94);

  &.no-transition { transition: none; }
}

.map-slide {
  flex-shrink: 0;
  box-sizing: border-box;
  max-width: 100%;
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
  gap: 8px;
  min-width: 0;
}

.map-slide-meta {
  display: flex;
  gap: 12px;
  min-width: 0;
  flex: 1;

  span {
    display: flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    color: rgba(255,255,255,0.4);
    white-space: nowrap;
  }
}

.map-slide-meta-row .act-btn {
  flex-shrink: 0;
  padding: 6px 12px;
  font-size: 11px;
}

// Garage card in the list view, including its expanded actions.

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

@keyframes slideDown {
  from { opacity: 0; transform: translateY(-6px); }
  to { opacity: 1; transform: translateY(0); }
}

// Offers on one listed property.

.listings-meta {
  color: rgba(255,255,255,0.6);
  font-size: 11px;
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

// End lease confirmation dialog.

.end-lease-overlay {
  position: absolute;
  inset: 0;
  z-index: 20;
  background: rgba(0, 0, 0, 0.6);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
}

.end-lease-modal {
  background: linear-gradient(180deg, rgba(26, 26, 26, 0.97) 0%, rgba(13, 13, 13, 0.97) 100%);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 16px;
  padding: 20px;
  width: 100%;
  max-width: 320px;
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
}

.end-lease-title {
  margin: 0 0 4px;
  font-size: 16px;
  font-weight: 700;
  color: white;
}

.end-lease-property {
  margin: 0 0 14px;
  font-size: 13px;
  color: #f97316;
  font-weight: 600;
}

.end-lease-fees {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 12px;
  padding: 12px;
  background: rgba(0, 0, 0, 0.3);
  border-radius: 10px;
}

.fee-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.55);
}

.fee-row .fee-val {
  font-weight: 700;
  color: #fca5a5;
  font-variant-numeric: tabular-nums;
}

.fee-divider {
  height: 1px;
  background: rgba(255, 255, 255, 0.08);
}

.fee-row.total {
  font-weight: 700;
  color: white;
}

.fee-row.total .fee-val {
  color: #ef4444;
  font-size: 13px;
}

.end-lease-note {
  margin: 0 0 16px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
  line-height: 1.4;
}

.end-lease-actions {
  display: flex;
  gap: 8px;
}

.modal-btn {
  flex: 1;
  padding: 10px 14px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.15s ease;
  &:hover { opacity: 0.85; }
}

.cancel-btn {
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.7);
  border: 1px solid rgba(255, 255, 255, 0.12);
}

.confirm-btn {
  background: rgba(239, 68, 68, 0.85);
  color: #fff;
}
</style>
