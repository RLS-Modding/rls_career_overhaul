<!--
  Map of vehicleShopping/VehicleList.vue
  Vehicle list owns search, filters, selected detail, entry focus and dealership actions.
  Read store-derived listings, filters and search, entry lifecycle, taxi actions, then detail actions.
  VehicleCard, VehicleDetail, FilterDropdown and SortDropdown keep their existing presentation roles.
-->
<!-- Buy side of the vehicle shop, house style. Sits top-left under the computer heading: a search
     field with neutral Filters / Sort, the dealerships as photo-first tiles (name bold, description
     muted, level as a slim bar, small rounded photos of their stock), then the listing rows. No
     orange on the many rows; status colour only by exception. Same data, store and Lua calls. -->
<template>
  <div
    class="rls-house vehicle-shop-wrapper"
    :class="{ 'vehicle-shop-wrapper--phone': phoneMode, 'detail-open': !!detailVehicle }"
    v-bng-blur
  >
    <!-- Header Section -->
    <div v-if="!phoneMode" class="header-section">
      <!-- Search and Filter Bar -->
      <div class="search-filter-bar">
        <label class="search shop-search" data-focus-field>
          <BngIcon :type="icons.search" class="search-icon" />
          <input
            v-model="localSearchQuery"
            placeholder="Search for a vehicle"
            @focus="onSearchFocus"
            @blur="onSearchBlur"
            @keydown.enter.stop="triggerSearch"
            @keydown.stop @keyup.stop @keypress.stop
            class="search-input"
            type="text"
            v-bng-text-input
          />
          <button
            v-if="localSearchQuery || activeSearchQuery"
            type="button"
            class="search-clear"
            title="Clear search"
            @mousedown.prevent
            @click="localSearchQuery = ''; triggerSearch()"
          >
            <BngIcon :type="icons.xmark" />
          </button>
        </label>

        <FilterDropdown
          :filters="vehicleShoppingStore.filters"
          :match-count="displayedVehicles.length"
          @add-filter="handleAddFilter"
          @remove-filter="removeFilter"
          @clear-filters="clearFilters"
        />

        <SortDropdown />
      </div>

      <!-- Active filters: one short chip each (click removes), then Clear all -->
      <div v-if="toolbarChips.length" class="active-chips">
        <button
          v-for="chip in toolbarChips"
          :key="chip.id"
          type="button"
          class="active-chip"
          bng-nav-item
          :title="`Remove ${chip.title}`"
          @click="removeToolbarChip(chip)"
        >
          <span v-if="chip.label" class="chip-key">{{ chip.label }}</span>
          <span v-if="chip.pre" class="chip-key">{{ chip.pre }}</span>
          <span class="chip-value" :class="{ money: chip.money }">
            <BngIcon v-if="chip.money" class="chip-cur" :type="icons.beamCurrency" />{{ chip.value }}
          </span>
          <BngIcon class="chip-x" :type="icons.xmark" />
        </button>
        <HouseButton variant="quiet" compact class="chips-clear" @click="clearFilters">Clear all</HouseButton>
      </div>
    </div>

    <!-- Main Content -->
    <!-- the directive (not the bare attributes) registers the right stick with the game's tracker -->
    <div ref="mainContentRef" class="main-content scroll" v-bng-ui-nav-scroll.force>

      <!-- Show current seller vehicles when at specific dealer -->
      <div v-if="vehicleShoppingStore?.vehicleShoppingData?.currentSeller" class="branch">
        <!-- Current dealership: photo, name, description, level -->
        <div class="dealer-hero">
          <div class="seller-photo">
            <img
              v-if="dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller]?.preview"
              :src="dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller].preview"
              alt=""
            />
            <BngIcon v-else class="photo-fallback" :type="dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller]?.icon || icons.carDealer" />
          </div>
          <div class="seller-copy">
            <h3 class="seller-name">{{ vehicleShoppingStore?.vehicleShoppingData?.currentSellerNiceName }}</h3>
            <p v-if="vehicleShoppingStore.vehicleShoppingData.currentSellerLocation" class="seller-description">{{ vehicleShoppingStore.vehicleShoppingData.currentSellerLocation }}</p>
            <p v-if="vehicleShoppingStore.vehicleShoppingData.currentSellerDescription" class="seller-description">{{ vehicleShoppingStore.vehicleShoppingData.currentSellerDescription }}</p>
            <div v-if="getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller)" class="rep">
              <div class="rep-head">
                <span class="rep-level">Level {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).level }}</span>
                <span class="rep-message" v-if="getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext > 0" title="Purchases to the next level">
                  {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext }} more
                </span>
                <span class="rep-message" v-else>Max</span>
              </div>
              <div class="rep-bar"><span :style="repFill(vehicleShoppingStore?.vehicleShoppingData?.currentSeller)"></span></div>
            </div>
          </div>
        </div>

        <p class="hint taxes">* Additional taxes and fees are applicable</p>

        <!-- No vehicles at this dealership -->
        <div v-if="displayedVehicles.length === 0" class="empty">
          <BngIcon :type="icons.cars" class="empty-icon" />
          <h3>No vehicles available</h3>
          <p>
            {{ vehicleShoppingStore?.vehicleShoppingData?.currentSellerNiceName || 'This dealership' }} currently has no vehicles in stock.
          </p>
        </div>

        <!-- Vehicles with pagination -->
        <template v-else>
          <div ref="vehicleListAnchorRef" class="vehicle-list-anchor">
            <div v-if="totalPages > 1" class="pager">
              <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
              <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
              <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
              <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
            </div>
            <div class="vehicle-listings">
              <VehicleCard v-for="(vehicle, key) in pageSlice(displayedVehicles)" :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle"
                :racing-team-shop="racingTeamVehicleShop" :phone-mode="phoneMode" :data-shop-key="vehicleKey(vehicle)" @open="openDetail(vehicle)" />
            </div>
          </div>
          <div v-if="totalPages > 1" class="pager">
            <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
            <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
            <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
          </div>
        </template>
      </div>

      <!-- Show search results when searching -->
      <div v-else-if="hasActiveSearch" class="branch">
        <div ref="vehicleListAnchorRef" class="content-header">
          <div class="content-heading">
            <h3 class="content-title">Search Results</h3>
            <span class="vehicle-count">{{ allFilteredVehicles.length }} vehicle{{ allFilteredVehicles.length !== 1 ? 's' : '' }} found</span>
          </div>
          <HouseMenu class="per-page" compact v-model="itemsPerPage" :items="pageSizeItems" />
        </div>
        <p class="hint taxes">* Additional taxes and fees are applicable</p>

        <!-- No search results -->
        <div v-if="allFilteredVehicles.length === 0" class="empty">
          <BngIcon :type="icons.search" class="empty-icon" />
          <h3>No search results</h3>
          <p>
            No vehicles match your search for "{{ activeSearchQuery }}". Try adjusting your search terms or filters.
          </p>
        </div>

        <!-- Search results with pagination -->
        <template v-else>
          <div v-if="totalPages > 1" class="pager">
            <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
            <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
            <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
          </div>
          <div class="vehicle-listings">
            <VehicleCard v-for="(vehicle, key) in pageSlice(allFilteredVehicles)" :key="vehicle.uid || vehicle.shopId"
              :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle"
              :racing-team-shop="racingTeamVehicleShop" :phone-mode="phoneMode" :data-shop-key="vehicleKey(vehicle)" @open="openDetail(vehicle)" />
          </div>
          <div v-if="totalPages > 1" class="pager">
            <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
            <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
            <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
          </div>
        </template>
      </div>

      <!-- Show main vehicle list with collapsible dealership section -->
      <div v-else class="branch">
        <!-- Dealership Selection -->
        <div v-if="!hideDealerPicker" class="dealership-section" :class="{ collapsed: !dealersOpen }">
          <button type="button" class="section-toggle" bng-nav-item @click="dealersOpen = !dealersOpen">
            <BngIcon :type="dealersOpen ? icons.arrowSmallDown : icons.arrowSmallRight" class="expand-icon" />
            <span class="caption section-title">Available Dealerships</span>
            <span v-if="hiddenDealers.length > 0" class="section-fact">
              {{ visibleDealers.length }} online, {{ hiddenDealers.length }} offline
            </span>
            <span class="section-fact discovery-progress">
              Dealerships discovered <b>{{ dealershipDiscovery.discovered }}/{{ dealershipDiscovery.total }}</b>
            </span>
          </button>

          <div class="dealership-content" v-if="dealersOpen">
            <!-- Visible Dealerships Grid -->
            <div class="dealership-grid" v-if="visibleDealers.length > 0">
              <button type="button"
                v-for="dealer in visibleDealers"
                :key="dealer.id"
                class="dealer-tile"
                :class="{
                  'no-rep': !hasRep(dealer.id),
                  'selected': selectedDealershipId === String(dealer.id)
                }"
                bng-nav-item
                @click.stop="navigateToDealership(dealer.id)"
                v-bng-route-target.id="{ route: 'overhaul.computer.vehicleShopping.vehicles', params: { sellerId: dealer.id } }"
                @mousedown.stop
              >
                <!-- photo fills the card; a top shade carries the name, the bottom carries level and stock -->
                <div class="dealer-photo">
                  <img v-if="dealerMetadata[dealer.id]?.preview" :src="dealerMetadata[dealer.id].preview" alt="" />
                  <BngIcon v-else class="photo-fallback" :type="dealerMetadata[dealer.id]?.icon || icons.carDealer" />
                </div>
                <div class="dealer-shade"></div>

                <div class="dealer-top">
                  <div class="dealer-name">
                    <BngIcon class="dealer-pin" :type="dealerMetadata[dealer.id]?.icon || icons.locationSource" />
                    <span>{{ dealerMetadata[dealer.id]?.name || dealer.name }}</span>
                  </div>
                  <div v-if="dealerMetadata[dealer.id]?.description" class="dealer-description">{{ dealerMetadata[dealer.id].description }}</div>
                </div>

                <div class="dealer-bottom">
                  <div v-if="getRepData(dealer.id)" class="dealer-rep" :title="repHint(dealer.id)">
                    <span class="dealer-rep-fill" :style="repFill(dealer.id)"></span>
                    <span class="dealer-rep-text">
                      <span>Level {{ getRepData(dealer.id).level }}</span>
                      <span v-if="getRepData(dealer.id).purchasesToNext > 0">{{ getRepData(dealer.id).purchasesToNext }} more</span>
                      <span v-else>Max</span>
                    </span>
                  </div>
                  <div v-if="dealer.vehicles.length > 0" class="dealer-thumbs">
                    <span
                      v-for="(vehicle, idx) in dealer.vehicles.slice(0, thumbCount(dealer))"
                      :key="vehicle.shopId || idx"
                      class="dealer-thumb"
                    >
                      <img v-if="vehicle.preview" :src="vehicle.preview" alt="" />
                      <BngIcon v-else :type="icons.car" />
                    </span>
                    <span v-if="dealer.vehicles.length > 5" class="dealer-thumb thumbs-more">+{{ dealer.vehicles.length - 4 }}</span>
                  </div>
                </div>
              </button>
            </div>

            <!-- Hidden Dealerships Section -->
            <div v-if="hiddenDealers.length > 0" class="hidden-dealers-section">
              <button type="button" class="section-toggle sub" bng-nav-item @click="hiddenDealersOpen = !hiddenDealersOpen">
                <BngIcon :type="hiddenDealersOpen ? icons.arrowSmallDown : icons.arrowSmallRight" class="expand-icon" />
                <span class="caption section-title">Offline Dealerships</span>
                <span class="section-fact">
                  {{ hiddenDealers.length }} dealer{{ hiddenDealers.length !== 1 ? 's' : '' }}
                </span>
              </button>

              <div class="dealership-grid" v-if="hiddenDealersOpen">
                <button type="button"
                  v-for="dealer in hiddenDealers"
                  :key="dealer.id"
                  class="dealer-tile hidden-card"
                  :class="{ 'locked-card': dealerMetadata[dealer.id]?.disabled }"
                  :aria-disabled="dealerMetadata[dealer.id]?.disabled ? 'true' : undefined"
                  bng-nav-item
                  @click="handleHiddenDealerClick(dealer)"
                  :title="dealerMetadata[dealer.id]?.disabled
                    ? dealerMetadata[dealer.id]?.disabledReason
                    : 'Not available online. Click to take a taxi to ' + (dealerMetadata[dealer.id]?.name || dealer.name)"
                >
                  <!-- photo fills the card; a top shade carries the name, the bottom carries level and stock -->
                  <div class="dealer-photo">
                    <img v-if="dealerMetadata[dealer.id]?.preview" :src="dealerMetadata[dealer.id].preview" alt="" />
                    <BngIcon v-else class="photo-fallback" :type="dealerMetadata[dealer.id]?.icon || icons.carDealer" />
                  </div>
                  <div class="dealer-shade"></div>
                    <span class="photo-tag">
                      <BngIcon :type="dealerMetadata[dealer.id]?.disabled ? icons.lockClosed : icons.fastTravel" />
                      {{ dealerMetadata[dealer.id]?.disabled ? 'Locked' : 'Taxi' }}
                    </span>

                  <div class="dealer-top">
                    <div class="dealer-name">
                      <BngIcon class="dealer-pin" :type="dealerMetadata[dealer.id]?.icon || icons.locationSource" />
                      <span>{{ dealerMetadata[dealer.id]?.name || dealer.name }}</span>
                    </div>
                    <div v-if="dealerMetadata[dealer.id]?.description" class="dealer-description">{{ dealerMetadata[dealer.id].description }}</div>
                      <div v-if="dealerMetadata[dealer.id]?.disabled && dealerMetadata[dealer.id]?.disabledReason" class="dealer-reason">
                        {{ dealerMetadata[dealer.id].disabledReason }}
                      </div>
                  </div>

                  <div class="dealer-bottom">
                    <div v-if="getRepData(dealer.id) && !dealerMetadata[dealer.id]?.disabled" class="dealer-rep" :title="repHint(dealer.id)">
                      <span class="dealer-rep-fill" :style="repFill(dealer.id)"></span>
                      <span class="dealer-rep-text">
                        <span>Level {{ getRepData(dealer.id).level }}</span>
                        <span v-if="getRepData(dealer.id).purchasesToNext > 0">{{ getRepData(dealer.id).purchasesToNext }} more</span>
                        <span v-else>Max</span>
                      </span>
                    </div>
                    <div v-if="dealer.vehicles.length > 0" class="dealer-thumbs">
                      <span
                        v-for="(vehicle, idx) in dealer.vehicles.slice(0, thumbCount(dealer))"
                        :key="vehicle.shopId || idx"
                        class="dealer-thumb"
                      >
                        <img v-if="vehicle.preview" :src="vehicle.preview" alt="" />
                        <BngIcon v-else :type="icons.car" />
                      </span>
                      <span v-if="dealer.vehicles.length > 5" class="dealer-thumb thumbs-more">+{{ dealer.vehicles.length - 4 }}</span>
                    </div>
                  </div>
                </button>
              </div>
            </div>
          </div>
        </div>

        <!-- Vehicle Listings -->
        <div ref="vehicleListAnchorRef" class="vehicles-section">
          <div ref="vehicleListHeaderRef" class="content-header" v-if="!phoneMode">
            <div class="content-heading">
              <h3 class="content-title">{{ selectedDealershipId ? (dealerMetadata[selectedDealershipId]?.name || 'Dealership') + ' Vehicles' : 'All Vehicles' }}</h3>
              <span class="vehicle-count">
                {{ displayedVehicles.length }} vehicle{{ displayedVehicles.length !== 1 ? 's' : '' }} found
              </span>
            </div>
            <HouseMenu class="per-page" compact v-model="itemsPerPage" :items="pageSizeItems" />
          </div>
          <p v-if="!phoneMode" class="hint taxes">* Additional taxes and fees are applicable</p>

          <div v-if="displayedVehicles.length === 0" class="empty">
            <BngIcon :type="icons.cars" class="empty-icon" />
            <h3>No vehicles available</h3>
            <p>
              {{ selectedDealershipId ? (dealerMetadata[selectedDealershipId]?.name || 'This dealership') + ' currently has no vehicles in stock.' : 'No vehicles match your current filters.' }}
            </p>
          </div>

          <div v-else class="vehicle-listings">
            <div v-if="totalPages > 1" class="pager">
              <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
              <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
              <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
              <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
            </div>

            <VehicleCard
              v-for="(vehicle, key) in pageSlice(displayedVehicles)"
              :key="key"
              :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
              :vehicle="vehicle"
              :racing-team-shop="racingTeamVehicleShop"
              :phone-mode="phoneMode" :data-shop-key="vehicleKey(vehicle)" @open="openDetail(vehicle)"
            />

            <!-- Only show pagination when there are multiple pages -->
            <div v-if="totalPages > 1" class="pager">
              <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
              <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</HouseButton>
              <span class="pager-page">Page {{ currentPage }} / {{ totalPages }}</span>
              <HouseButton variant="quiet" compact :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" /></HouseButton>
            </div>
          </div>

          <!-- Recently Sold Section -->
          <div v-if="!phoneMode && relevantSoldVehicles.length > 0" class="sold-section">
            <div class="sold-header">
              <span class="caption">Recently Sold</span>
              <span class="section-fact">{{ relevantSoldVehicles.length }} vehicle{{ relevantSoldVehicles.length !== 1 ? 's' : '' }}</span>
            </div>
            <div class="vehicle-listings">
              <VehicleCard
                v-for="(vehicle, key) in relevantSoldVehicles"
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
                :vehicle="vehicle"
                :racing-team-shop="racingTeamVehicleShop"
                :phone-mode="phoneMode" :data-shop-key="vehicleKey(vehicle)" @open="openDetail(vehicle)"
              />
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- detail page for one listing; the list above keeps its page, filters and scroll -->
    <VehicleDetail
      v-if="detailVehicle"
      :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
      :vehicle="detailVehicle"
      :racing-team-shop="racingTeamVehicleShop"
      :back-label="detailBackLabel"
      @back="closeDetail" />
  </div>
</template>

<script setup>
import { reactive, onMounted, onBeforeUnmount, ref, shallowRef, computed, watch, nextTick } from "vue"
import { useRoute } from "vue-router"
import { useRouteDataStore } from '@/services/routeData'
import VehicleCard from "./VehicleCard.vue"
import VehicleDetail from "./VehicleDetail.vue"
import { shopDetail } from "./useShopVehicle"
import FilterDropdown from "./FilterDropdown.vue"
import SortDropdown from "./SortDropdown.vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseMenu, openHouseConfirmation } from "../house/index.js"
import { vBngBlur, vBngTextInput, vBngUiNavScroll, vBngRouteTarget } from "@/common/directives"
import { refocusIfLost, returnFocusToOpener } from "../../composables/useScreenEntryFocus"
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { shopFilterUnit } from "../../utils/units"
import { safeLua } from "../../utils/safeLua.js"

const ENTRY_REFOCUS_DELAY_MS = 500
const ENTRY_MARK_DROP_MS = 10000

const props = defineProps({
  phoneMode: { type: Boolean, default: false },
  hideDealerPicker: { type: Boolean, default: false },
  fixedSellerId: { type: String, default: null },
})

const vehicleShoppingStore = useVehicleShoppingStore()

// toolbar: active filters as short removable chips under the search row ("Price up to 10,000",
// "Year 1990–2010", "FWD"). Ranges remove the whole filter; a picked value toggles just that value.
const TOOLBAR_RANGE_NAMES = { Value: "Price", year: "Year", Mileage: "Mileage", Power: "Power", Weight: "Weight" }
// range filters are held in the player's units (see shopFilterUnit)
const toolbarRangeUnit = key => (["Mileage", "Power", "Weight"].includes(key) ? ` ${shopFilterUnit(units, key).label}` : "")
const toolbarChips = computed(() => {
  const chips = []
  const filters = vehicleShoppingStore.filters || {}
  const num = (key, n) => (key === "year" ? String(n) : Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 }))
  for (const [key, f] of Object.entries(filters)) {
    if (!f) continue
    if (key === "hideSold") {
      if (f.value === true || (Array.isArray(f.values) && f.values.length)) chips.push({ id: "hideSold", key, kind: "flag", value: "Hide sold", title: "Hide sold" })
      continue
    }
    const hasMin = Number.isFinite(f.min)
    const hasMax = Number.isFinite(f.max)
    if (hasMin || hasMax) {
      const label = TOOLBAR_RANGE_NAMES[key] || key
      const unit = toolbarRangeUnit(key)
      const pre = hasMin && hasMax ? "" : hasMax ? "up to" : "from"
      const value = hasMin && hasMax ? `${num(key, f.min)}–${num(key, f.max)}${unit}` : `${num(key, hasMax ? f.max : f.min)}${unit}`
      chips.push({ id: `${key}:range`, key, kind: "range", label, pre, value, money: key === "Value", title: `${label} filter` })
    }
    for (const v of f.values || []) chips.push({ id: `${key}:${v}`, key, kind: "value", raw: v, value: String(v), title: String(v) })
  }
  return chips
})
function removeToolbarChip(chip) {
  if (chip.kind === "value") vehicleShoppingStore.toggleFilterValue(chip.key, chip.raw)
  else removeFilter(chip.key)
  refocusIfLost(() => document.querySelector('.vehicle-shop-wrapper .filter-btn'))
}
function clearFilters() {
  vehicleShoppingStore.clearAllFilters()
  refocusIfLost(() => document.querySelector('.vehicle-shop-wrapper .filter-btn'))
}

// ---- detail page: one listing at a time, looked up by shop id so sold/price updates still reach it
const detailSnapshot = shallowRef(null)
let listScrollTop = 0
const vehicleKey = v => v?.shopId || v?.id || v?.uid
const detailVehicle = computed(() => {
  if (shopDetail.value == null) return null
  const d = vehicleShoppingStore.vehicleShoppingData?.vehiclesInShop
  const list = Array.isArray(d) ? d : Object.values(d || {})
  const live = list.find(v => vehicleKey(v) === shopDetail.value)
  if (live) return { ...detailSnapshot.value, ...live }
  // the listing left the shop while its page was open (bought elsewhere, expired, refreshed out): show it as gone
  return detailSnapshot.value ? { ...detailSnapshot.value, __sold: true } : null
})
const openDetail = async vehicle => {
  if (props.phoneMode) return
  listScrollTop = mainContentRef.value?.scrollTop || 0
  detailSnapshot.value = vehicle
  const id = vehicleKey(vehicle)
  shopDetail.value = id
  const listing = await lua.overhaul_career_market_vehicleShopping.getListing(id)
  if (shopDetail.value === id) detailSnapshot.value = listing || { ...vehicle, __sold: true }
}
const closeDetail = () => {
  shopDetail.value = null
}
// back on the list: put it where it was
watch(shopDetail, (id, prev) => {
  if (id == null && prev != null) {
    detailSnapshot.value = null
    nextTick(() => {
      if (mainContentRef.value) mainContentRef.value.scrollTop = listScrollTop
      // controller: back on the card that was opened
      returnFocusToOpener(() => {
        const card = [...document.querySelectorAll(".vehicle-shop-wrapper [data-shop-key]")].find(el => el.dataset.shopKey === String(prev))
        return card?.querySelector(".vc-open") || card
      })
    })
  } else if (id != null && prev == null) {
    // controller: the list is hidden under the detail page, so focus would fall to <body>; start on
    // the page's first usable action (Buy / Inspect ...), else its back button
    returnFocusToOpener(() =>
      document.querySelector(".vehicle-detail .vd-actions button:not([disabled])") ||
      document.querySelector(".vehicle-detail .vd-back"))
  }
}, { flush: "post" })
const detailBackLabel = computed(() => {
  const d = vehicleShoppingStore.vehicleShoppingData
  if (d?.currentSellerNiceName) return `Back to ${d.currentSellerNiceName}`
  if (selectedDealershipId.value) return `Back to ${dealerMetadata.value?.[selectedDealershipId.value]?.name || "the dealership"}`
  return "Back to all vehicles"
})
const events = useEvents()
const { units } = useBridge()
const route = useRoute()
const entryRouteTarget = useRouteDataStore().fromRouteTarget
const racingTeamVehicleShop = computed(() => {
  const q = route.query.rtBiz
  return (q !== undefined && q !== null && String(q) !== "") || !!vehicleShoppingStore.vehicleShoppingData.racingTeamBusinessId
})
let onDeltaRef = null
const dealerMetadata = computed(() => Object.fromEntries(
  (vehicleShoppingStore.vehicleShoppingData?.dealerships || []).map(dealer => [dealer.id, dealer])
))
const inputFocused = ref(false)
// the store keeps the search across visits; start the bar from it so a still-active search is visible
const localSearchQuery = ref(vehicleShoppingStore.searchQuery || '')
const activeSearchQuery = ref(vehicleShoppingStore.searchQuery || '')
const dealersOpen = ref(route.name !== 'overhaul.computer.vehicleShopping.vehicles')
const itemsPerPage = ref(props.phoneMode ? 100 : 25)
const pageSizeOptions = [10, 25, 50, 100]
const pageSizeItems = pageSizeOptions.map(n => ({ value: n, label: `${n} per page` }))
const currentPage = ref(1)
const hiddenDealersOpen = ref(false)
const mainContentRef = ref(null)
const vehicleListHeaderRef = ref(null)
const vehicleListAnchorRef = ref(null)

const orgsById = computed(() => (vehicleShoppingStore?.vehicleShoppingData?.organizations) || {})
const dealershipDiscovery = computed(() => {
  const progress = vehicleShoppingStore?.vehicleShoppingData?.dealershipDiscovery || {}
  const total = Math.max(0, Number(progress.total) || 0)
  return {
    discovered: Math.min(total, Math.max(0, Number(progress.discovered) || 0)),
    total,
  }
})

// level tooltip: what the bar means in words
const repHint = dealerId => {
  const rep = getRepData(dealerId)
  if (!rep) return undefined
  return rep.purchasesToNext > 0 ? `${rep.purchasesToNext} more purchase${rep.purchasesToNext === 1 ? "" : "s"} to level ${rep.level + 1}` : "Top level"
}

function getRepData(dealerId) {
  const orgId = dealerMetadata.value[dealerId] && dealerMetadata.value[dealerId].associatedOrganization
  if (!orgId) return null
  const org = orgsById.value[orgId]
  if (!org || !org.reputation) return null

  const level = typeof org.reputation.level === 'number' ? org.reputation.level : 0
  let pct = 0
  let percentage = 0
  let reputationToNext = 0
  let purchasesToNext = 0

  const cur = org.reputation.curLvlProgress
  const need = org.reputation.neededForNext
  const purchaseRepGain = Number(vehicleShoppingStore?.vehicleShoppingData?.dealershipPurchaseReputationGain) || 786

  if (typeof cur === 'number' && typeof need === 'number' && need > 0) {
    pct = Math.max(0, Math.min(1, cur / need))
    percentage = Math.round(pct * 100)
    reputationToNext = Math.max(0, need - cur)
    purchasesToNext = Math.ceil(reputationToNext / Math.max(1, purchaseRepGain))
  }

  return { level, pct, percentage, reputationToNext, purchasesToNext }
}

const selectedDealershipId = computed(() => {
  if (props.fixedSellerId) return props.fixedSellerId
  return (
    route.params.selectedSellerId ||
    vehicleShoppingStore.selectedSellerId ||
    vehicleShoppingStore.vehicleShoppingData?.selectedSellerId ||
    null
  )
})

const displayedVehicles = computed(() => {
  if (hasActiveSearch.value) return allFilteredVehicles.value

  if (selectedDealershipId.value && !vehicleShoppingStore.vehicleShoppingData.currentSeller) {
    return vehicleShoppingStore.filteredVehicles.filter(v => v.sellerId === selectedDealershipId.value)
  }

  return vehicleShoppingStore.filteredVehicles
})

const totalItems = computed(() => {
  return displayedVehicles.value.length
})

const totalPages = computed(() => {
  return Math.max(1, Math.ceil(totalItems.value / itemsPerPage.value))
})

function pageSlice(list) {
  const start = (currentPage.value - 1) * itemsPerPage.value
  const end = start + itemsPerPage.value
  return (Array.isArray(list) ? list : []).slice(start, end)
}

const pageStart = computed(() => {
  if (totalItems.value === 0) return 0
  return (currentPage.value - 1) * itemsPerPage.value + 1
})
const pageEnd = computed(() => Math.min(totalItems.value, currentPage.value * itemsPerPage.value))

// Trigger search only on explicit action (Enter key or blur)
const triggerSearch = () => {
  activeSearchQuery.value = localSearchQuery.value.trim()
  inputFocused.value = false // Reset focus state
  vehicleShoppingStore.setSearchQuery(activeSearchQuery.value)
}

// CEF typing for the search field belongs to its v-bng-text-input directive, which also releases it on unmount
function onSearchFocus() {
  inputFocused.value = true
}

function onSearchBlur() {
  safeLua(() => triggerSearch(), "Apply shop search on blur")
}

// Use a separate variable to track if we have an active search
const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

// Collect all vehicles across all dealers when searching
const allFilteredVehicles = computed(() => {
  if (!hasActiveSearch.value) return []

  const query = activeSearchQuery.value.toLowerCase()
  let allVehicles = []

  // If we're at a specific dealer, use filteredVehicles
  if (vehicleShoppingStore?.vehicleShoppingData?.currentSeller) {
    return vehicleShoppingStore.filteredVehicles
  }

  // Otherwise collect vehicles from all dealers (excluding hidden/offline dealers)
  vehicleShoppingStore.vehiclesByDealer.forEach(dealer => {
    // Skip vehicles from hidden/offline dealers during search
    if (dealer.hidden) return

    dealer.vehicles.forEach(vehicle => {
      const searchFields = [
        vehicle.Name,
        vehicle.Brand,
        vehicle.niceName,
        vehicle.model_key,
        vehicle.config_name,
      ]

      const matchesSearch = searchFields.some(field =>
        field && field.toString().toLowerCase().includes(query)
      )

      if (matchesSearch) {
        allVehicles.push(vehicle)
      }
    })
  })

  // Sort by price
  return vehicleShoppingStore.processVehicleList(allVehicles)
})

const relevantSoldVehicles = computed(() => {
  let sold = vehicleShoppingStore.filteredSoldVehicles || []

  // Filter by current seller (physically at dealer)
  if (vehicleShoppingStore.vehicleShoppingData?.currentSeller) {
    sold = sold.filter(v => v.sellerId === vehicleShoppingStore.vehicleShoppingData.currentSeller)
  }

  return sold
})

watch(
  () => shopDetail.value != null
    ? String(shopDetail.value)
    : pageSlice(displayedVehicles.value).map(vehicle => vehicleKey(vehicle)).join(','),
  ids => {
    if (!props.phoneMode && ids) safeLua(
      () => lua.overhaul_career_market_vehicleShopping.requestVehicleTravelQuotes(ids.split(',')),
      "Request visible vehicle travel quotes"
    )
  },
  { immediate: true }
)

// The route's parent owns the snapshot request; metadata and cards use that same response.
onMounted(() => {
  // Subscribe to deltas via events
  const onDelta = (delta) => {
    if (vehicleShoppingStore && typeof vehicleShoppingStore.applyShopDelta === 'function') vehicleShoppingStore.applyShopDelta(delta)
  }
  events.on('vehicleShopDelta', onDelta)
  onDeltaRef = onDelta
})

// Notify Lua that UI is open; Lua handles timed refresh internally
onMounted(() => { safeLua(() => lua.overhaul_career_market_vehicleShopping.setShoppingUiOpen(true), "Open shopping UI state") })

// Controller entry: start in the list body (first dealer or vehicle), never on the search box (focusing
// it turns on CEF typing). The scope's autofocus mark covers route-entry activation; it is removed
// again so later scope resumes (after a popup) return to the last focused card, not the top.
const pickListEntry = () =>
  (route.name === 'overhaul.computer.vehicleShopping.vehicles' && mainContentRef.value?.querySelector('.vc-open')) ||
  [...(mainContentRef.value?.querySelectorAll('[bng-route-target]') || [])].find(el => el.getAttribute('bng-route-target') === entryRouteTarget) ||
  mainContentRef.value?.querySelector('[bng-nav-item]:not([bng-no-nav="true"]):not([disabled]), button:not([disabled]):not([bng-no-nav="true"])')
let entryMarked = null
watch(
  () => vehicleShoppingStore.vehicleShoppingData?.vehiclesInShop,
  async data => {
    if (entryMarked !== null || !data) return
    await nextTick()
    entryMarked = pickListEntry() || false
    if (!entryMarked) return
    entryMarked.setAttribute("bng-scoped-nav-autofocus", "")
    setTimeout(() => {
      const active = document.activeElement
      if (!active || active === document.body || active.closest?.(".header-section")) refocusIfLost(pickListEntry, { force: true })
    }, ENTRY_REFOCUS_DELAY_MS)
    // drop the mark once the player has moved on from it (the route's scope activation can come before
    // or after this), or after a while at the latest
    const drop = () => entryMarked?.removeAttribute?.("bng-scoped-nav-autofocus")
    entryMarked.addEventListener("focusout", drop, { once: true })
    setTimeout(drop, ENTRY_MARK_DROP_MS)
  },
  { immediate: true }
)

onBeforeUnmount(() => {
  shopDetail.value = null
  safeLua(() => lua.overhaul_career_market_vehicleShopping.setShoppingUiOpen(false), "Close shopping UI state")
  // Unsubscribe from deltas if events exposes off
  safeLua(() => {
    if (events && typeof events.off === 'function' && typeof onDeltaRef === 'function') {
      events.off('vehicleShopDelta', onDeltaRef)
    }
  }, "Unsubscribe shop deltas")
})

const getHeaderText = () => {
  const data = vehicleShoppingStore ? vehicleShoppingStore.vehicleShoppingData : {}
  if (data.currentSeller == null || data.currentSeller === undefined) {
    return "BeamCar24"
  }
  return data.currentSellerNiceName
}




const sortedDealers = computed(() => {
  return vehicleShoppingStore.vehiclesByDealer.slice().sort((a, b) => {
    const nameA = dealerMetadata.value[a.id]?.name || a.name;
    const nameB = dealerMetadata.value[b.id]?.name || b.name;
    return nameA.localeCompare(nameB);
  });
});

const visibleDealers = computed(() => {
  return sortedDealers.value.filter(dealer => !dealer.hidden && !dealerMetadata.value[dealer.id]?.undiscovered);
});

const hiddenDealers = computed(() => {
  return sortedDealers.value.filter(dealer => dealer.hidden && !dealerMetadata.value[dealer.id]?.undiscovered);
});

// Reset pagination when the list context changes
watch([itemsPerPage, hasActiveSearch], () => {
  currentPage.value = 1
})

// After dealer filter, search, or other filters shrink the list, stay on a valid page
// (otherwise pageSlice uses a stale page index and shows nothing; pagination UI hides when totalPages === 1)
watch(totalPages, (tp) => {
  if (currentPage.value > tp) currentPage.value = 1
})

function scrollVehicleListToTop() {
  nextTick(() => {
    const container = mainContentRef.value
    if (!container) return
    // Dealers and vehicles share one scroll container — pin to the vehicle
    // list start so page changes don't yank you back up into dealerships.
    const target = vehicleListAnchorRef.value || vehicleListHeaderRef.value
    if (target && container.contains(target)) {
      const containerTop = container.getBoundingClientRect().top
      const targetTop = target.getBoundingClientRect().top
      container.scrollTop += targetTop - containerTop
      return
    }
    container.scrollTop = 0
  })
}

// Prev/Next leave you at the bottom of the scroll area; jump back to the vehicle list.
watch(currentPage, () => {
  // controller: paging from a pager button continues on the new page's first card, not on a pager
  // button that just scrolled out of view
  if (document.activeElement?.closest?.(".pager")) {
    refocusIfLost(() => mainContentRef.value?.querySelector(".vehicle-listings .vc-open"), { force: true })
  }
  scrollVehicleListToTop()
})

// Display helpers: level bar fill (transform only) and how many stock thumbs a tile shows
// (four photos plus a "+N" cell when there are more than five).
function repFill(dealerId) {
  const rep = getRepData(dealerId)
  return { transform: `scaleX(${rep ? rep.pct : 0})` }
}
function thumbCount(dealer) {
  return dealer.vehicles.length > 5 ? 4 : 5
}

// Helper: check if dealer has organization reputation
function hasRep(dealerId) {
  const meta = dealerMetadata.value[dealerId]
  if (!meta || !meta.associatedOrganization) return false
  const org = orgsById.value[meta.associatedOrganization]
  return !!(org && org.reputation)
}


async function taxiToDealer(dealershipId) {
  try {
    await lua.overhaul_career_market_vehicleShopping.taxiToDealership(dealershipId)
    if (racingTeamVehicleShop.value) {
      await lua.overhaul_career_market_vehicleShopping.selectSeller(String(dealershipId))
    }
  } catch (e) {
    safeLua(() => { throw e }, "Taxi to dealership")
    // Show error message to user
    // ui_message is a Lua global, not a browser one: send it through the bridge
    lua.ui_message(`Failed to taxi to dealership: ${e.message || 'Unknown error'}`, 5, "vehicleShopping")
  }
}

async function confirmTaxi(dealershipId) {
  try {
    const dealer = dealerMetadata.value[dealershipId]
    if (dealer?.disabled) {
      await lua.overhaul_career_market_vehicleShopping.navigateToDealership(dealershipId)
      return
    }

    const price = await lua.overhaul_career_market_vehicleShopping.getTaxiPriceToDealership(dealershipId)

    const name = dealerMetadata.value[dealershipId]?.name || 'Dealership'

    // Always show a numeric price using BeamNG formatting (0 shows as 0)
    const priceDisplay = units.beamBucks(Math.max(0, Number(price) || 0))

    // Use the proper BeamNG UI confirmation system like VehicleCard.vue does
    const res = await openHouseConfirmation("", `Taxi to ${name} for ${priceDisplay}?`, [
      { label: "Yes", value: true, extras: { default: true } },
      { label: "No", value: false, extras: { cancel: true } },
    ])

    if (res) {
      await taxiToDealer(dealershipId)
    }
  } catch (e) {
    safeLua(() => { throw e }, "Confirm taxi to dealership")
    // If confirmation fails, show an error message
    // ui_message is a Lua global, not a browser one: send it through the bridge
    lua.ui_message(`Failed to taxi to dealership: ${e.message || 'Unknown error'}`, 5, "vehicleShopping")
  }
}

async function handleHiddenDealerClick(dealer) {
  if (dealerMetadata.value[dealer.id]?.disabled) {
    await lua.overhaul_career_market_vehicleShopping.navigateToDealership(dealer.id)
    return
  }
  await confirmTaxi(dealer.id)
}

// Filter handling functions
const handleAddFilter = (filter) => {
  if (filter.type === 'range') {
    vehicleShoppingStore.setFilterRange(filter.category, filter.value[0], filter.value[1])
  } else if (filter.type === 'select') {
    vehicleShoppingStore.toggleFilterValue(filter.category, filter.value)
  } else if (filter.type === 'boolean') {
    // For boolean filters, set the value directly
    vehicleShoppingStore.setValueFilter(filter.category, [filter.value])
  }
}

function removeFilter(key) {
  // Clear the filter by removing it entirely
  if (key === 'hideSold') {
    vehicleShoppingStore.setValueFilter(key, [])
  } else {
    vehicleShoppingStore.setFilterRange(key)
  }
}

async function navigateToDealership(dealershipId) {
  dealershipId = String(dealershipId)
  const isDeselecting = String(selectedDealershipId.value || "") === dealershipId

  if (isDeselecting) {
    if (route.name === "overhaul.computer.vehicleShopping.vehicles") {
      await lua.extensions.ui_router.back()
    } else {
      vehicleShoppingStore.setSelectedSellerId("")
    }
  } else {
    // Keep Vue selection in sync when already on the vehicles route (Lua navigate is a no-op).
    vehicleShoppingStore.setSelectedSellerId(dealershipId)
    await lua.overhaul_career_market_vehicleShopping.selectSeller(dealershipId)
  }
}


</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* the buy tab: near-black house card top-left under the computer heading (same surface as the sell
   tab); grows with its content up to the screen height, the list scrolls inside. em off a
   resolution-scaled font. */
.vehicle-shop-wrapper {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  flex: 0 1 auto;
  min-height: 0;
  max-height: 100%;
  width: min(64em, 100%);
  display: flex;
  flex-direction: column;
  margin: 0;
  overflow: hidden;
  color: #fff;
  background: rgba(21, 21, 23, 0.93);
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

/* ---- search, filters, sort */
.header-section {
  flex: 0 0 auto;
  position: relative;
  z-index: 5;
  padding: 0.9em 1.1em 0.75em;
  border-bottom: 1px solid var(--line);
}
.search-filter-bar {
  display: flex;
  align-items: stretch;
  flex-wrap: wrap;
  gap: var(--space-2);
}
.shop-search {
  flex: 1 1 18em;
  width: auto;
  min-width: 14em;
  min-height: 2.3em;
  cursor: text;
  .search-icon {
    flex: 0 0 auto;
    font-size: 1.1em;
    color: var(--faint);
  }
  .search-input {
    font-size: 1em;
  }
  .search-clear {
    flex: 0 0 auto;
    font-size: 0.9em;
    :deep(.icon-base),
    .bng-icon {
      font-size: 0.8em;
    }
  }
}

/* active filters: neutral chips (label faint, value white, money gold), whole chip removes */
.active-chips {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.4em;
  margin-top: 0.6em;
}
.active-chip {
  position: relative;
  appearance: none;
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  margin: 0;
  padding: 0.5em 0.55em 0.38em 0.75em;
  border: 0;
  border-radius: var(--radius-control);
  background: var(--panel);
  color: #fff;
  font: inherit;
  font-size: 0.85em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
  transition: background-color 0.12s;
  .chip-key {
    color: var(--faint);
  }
  .chip-value.money {
    color: var(--money);
  }
  .chip-cur {
    margin-right: 0.1em;
    font-size: 0.95em;
    transform: translateY(0.05em);
  }
  .chip-x {
    margin-left: 0.1em;
    font-size: 0.85em;
    color: var(--faint);
    transform: translateY(-0.05em);
  }
  &:hover {
    background: var(--panel-2);
    .chip-x {
      color: #fff;
    }
  }
  @include house-focus;
}
.chips-clear {
  font-size: 0.85em;
}

/* ---- scrolling content */
.main-content {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  padding: 1em 0.6em 1.2em 1.1em;
}
.branch {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
  padding-right: 0.4em;
}
.taxes {
  margin: -0.35em 0 0;
  font-size: 0.78em;
}

/* "All Vehicles" + count, page size on the right */
.content-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 1em;
}
.content-heading {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 0.2em 0.75em;
  min-width: 0;
}
.content-title {
  margin: 0;
  font-size: 1.25em;
  font-weight: 800;
  line-height: 1.15;
}
.vehicle-count {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.per-page {
  flex: 0 0 auto;
  font-size: 0.88em;
  :deep(.menu-list) {
    left: auto;
    right: 0;
  }
}

/* ---- pager: compact quiet buttons around the page number */
.pager {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 0.35em 0.5em;
  font-variant-numeric: tabular-nums;
}
.pager-range {
  margin-right: auto;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
}
.pager-page {
  min-width: 6.5em;
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 700;
  text-align: center;
}
.pager-chev {
  font-size: 1.1em;
  margin-left: 0.15em;
  transform: translateY(0.05em);
}

/* ---- level: label row + slim bar, accent only on the fill */
.rep {
  display: grid;
  gap: 0.3em;
}
.rep-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  font-size: 0.8em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.rep-level {
  color: var(--muted);
}
.rep-message {
  color: var(--faint);
  font-weight: 600;
}
.rep-bar {
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  > span {
    display: block;
    height: 100%;
    background: var(--accent);
    transform-origin: left center;
    transition: transform 0.3s ease;
  }
}

/* shared photo fallback (plain glyph, no badge) */
.photo-fallback {
  font-size: 2.4em;
  color: rgba(255, 255, 255, 0.22);
}

/* ---- current dealership (player is at the lot) */
.dealer-hero {
  display: grid;
  grid-template-columns: minmax(0, 11em) minmax(0, 1fr);
  gap: 1.1em;
  align-items: center;
  padding: 0.55em 1em 0.55em 0.55em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.seller-photo {
  display: grid;
  place-items: center;
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
.seller-copy {
  display: grid;
  gap: 0.45em;
  min-width: 0;
  .rep {
    max-width: 22em;
    margin-top: 0.2em;
  }
}
.seller-name {
  overflow-wrap: anywhere;
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
}
.seller-description {
  overflow-wrap: anywhere;
  margin: 0;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.35;
}

/* ---- dealerships: caption toggle, then photo-first tiles */
.dealership-section {
  display: grid;
  gap: 0.6em;
}
.section-toggle {
  width: 100%;
  border: 0;
  background: transparent;
  text-align: left;
  font: inherit;
  color: inherit;
  position: relative;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.3em 0.9em;
  padding: 0.35em 0.4em 0.25em 0.15em;
  border-radius: var(--radius-thumb);
  cursor: pointer;
  user-select: none;
  &:hover {
    background: rgba(255, 255, 255, 0.04);
  }
  @include house-focus;
  .expand-icon {
    margin-right: -0.5em;
    font-size: 1.1em;
    color: var(--faint);
  }
  .section-title {
    font-size: 0.78em;
  }
}
.section-fact {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  b {
    color: var(--muted);
    font-weight: 800;
  }
}
.discovery-progress {
  margin-left: auto;
}

.dealership-content {
  display: grid;
  gap: 0.85em;
}
.dealership-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(20em, 1fr));
  gap: 0.6em;
  align-items: stretch;
}

/* dealer card: the photo is the card; name and description sit on a top shade, level and stock along the bottom */
.dealer-tile {
  border: 0;
  text-align: left;
  font: inherit;
  padding: 0;
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  height: 14em;
  min-width: 0;
  border-radius: var(--radius-panel);
  overflow: hidden;
  background: var(--photo);
  box-shadow: inset 0 0 0 1px var(--line);
  color: #fff;
  cursor: pointer;
  transition: transform 0.15s ease, box-shadow 0.15s ease;
  &:hover {
    transform: translateY(-0.12em);
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.22), 0 0.6em 1.4em rgba(0, 0, 0, 0.35);
  }
  // overflow:hidden clips the game's ::before frame; the house ring is a box-shadow and is not clipped
  @include house-focus;
  &.selected {
    box-shadow: 0 0.6em 1.4em rgba(0, 0, 0, 0.35);
    // the photo covers an inset shadow, so the selected ring is drawn on a layer above it
    &::after {
      content: "";
      position: absolute;
      inset: 0;
      z-index: 2;
      border-radius: inherit;
      box-shadow: inset 0 0 0 2px var(--accent);
      pointer-events: none;
    }
  }
  &.hidden-card .dealer-photo img {
    filter: saturate(55%);
  }
  &.locked-card {
    cursor: default;
    .dealer-photo img {
      filter: brightness(50%) saturate(30%);
    }
  }
}
.dealer-photo {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .photo-fallback {
    font-size: 3em;
    color: rgba(255, 255, 255, 0.22);
  }
}
.dealer-shade {
  position: absolute;
  inset: 0;
  background:
    linear-gradient(180deg, rgba(0, 0, 0, 0.86) 0%, rgba(0, 0, 0, 0.62) 28%, rgba(0, 0, 0, 0.2) 52%, rgba(0, 0, 0, 0) 66%),
    linear-gradient(0deg, rgba(0, 0, 0, 0.92) 0%, rgba(0, 0, 0, 0.6) 22%, rgba(0, 0, 0, 0) 45%);
  pointer-events: none;
}
.photo-tag {
  position: absolute;
  top: 0.6em;
  right: 0.6em;
  z-index: 2;
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  padding: 0.42em 0.55em 0.18em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.8);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  .bng-icon,
  :deep(.icon-base) {
    transform: translateY(-0.1em);
  }
}
.dealer-top {
  position: relative;
  z-index: 1;
  display: grid;
  gap: 0.2em;
  padding: 0.75em 0.8em 0;
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.6);
}
.dealer-name {
  display: flex;
  align-items: center;
  gap: 0.45em;
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.2;
  .dealer-pin {
    flex: 0 0 auto;
    font-size: 1.05em;
  }
}
.dealer-description {
  color: rgba(255, 255, 255, 0.88);
  font-size: 0.82em;
  font-weight: 600;
  line-height: 1.35;
}
.dealer-reason {
  color: var(--faint);
  font-size: 0.8em;
  font-weight: 600;
  line-height: 1.3;
}
.dealer-bottom {
  position: relative;
  z-index: 1;
  display: grid;
  gap: 0.4em;
  padding: 0 0.45em 0.45em;
}
/* level: one wide bar, label and "N more" inside it */
.dealer-rep {
  position: relative;
  height: 1.45em;
  border-radius: var(--radius-pill);
  overflow: hidden;
  background: rgba(255, 255, 255, 0.12);
}
.dealer-rep-fill {
  position: absolute;
  inset: 0;
  background: var(--accent);
  opacity: 0.85;
  transform-origin: left center;
  transition: transform 0.3s ease;
}
.dealer-rep-text {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 100%;
  padding: 0.12em 0.55em 0;
  font-size: 0.74em;
  font-weight: 800;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
/* stock: five photos across the bottom, the fifth "+N" when there are more */
.dealer-thumbs {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 0.35em;
}
.dealer-thumb {
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: rgba(30, 30, 33, 0.85);
  color: rgba(255, 255, 255, 0.3);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &.thumbs-more {
    color: #fff;
    font-size: 0.95em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
}

.hidden-dealers-section {
  display: grid;
  gap: 0.6em;
}

/* ---- listings */
.vehicles-section {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
}
.vehicle-list-anchor {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
}
.vehicle-listings {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

/* ---- empty state: plain glyph, no badge */
.empty {
  border-radius: var(--radius-panel);
  background: var(--panel);
  padding: 2.4em 1.2em;
  .empty-icon {
    font-size: 2.4em;
    color: var(--faint);
  }
}

/* ---- recently sold */
.sold-section {
  display: grid;
  gap: 0.6em;
  margin-top: 0.6em;
  padding-top: 0.9em;
  border-top: 1px solid var(--line);
}
.sold-header {
  display: flex;
  align-items: baseline;
  gap: 0.8em;
}
.sold-section :deep(.vehicle-card) {
  opacity: 0.8;
}

/* ---- phone */
.vehicle-shop-wrapper--phone {
  font-size: inherit;
  width: 100%;
  background: transparent;
  border-radius: 0;
  box-shadow: none;
  .main-content {
    padding: 0;
  }
  .branch {
    padding-right: 0;
  }
  .vehicle-listings {
    gap: 0.5em;
  }
  .pager {
    justify-content: center;
  }
}

/* ---- detail page open: the list (and its toolbar) step aside, keeping their state */
.vehicle-shop-wrapper.detail-open > .header-section,
.vehicle-shop-wrapper.detail-open > .main-content {
  display: none;
}
</style>
