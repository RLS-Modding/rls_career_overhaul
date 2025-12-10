<template>
  <BngCard class="vehicle-shop-wrapper" v-bng-blur bng-ui-scope="vehicleList">
    <!-- Header Section -->
    <div class="header-section">
        <!-- Search and Filter Bar -->
        <div class="search-filter-bar">
          <div class="search-section">
            <BngIcon :type="icons.search" class="search-icon" />
            <input 
              v-model="localSearchQuery" 
              placeholder="Search for a vehicle..." 
              @focus="onSearchFocus"
              @blur="onSearchBlur" 
              @keydown.enter.stop="triggerSearch" 
              @keydown.stop @keyup.stop @keypress.stop
              class="search-input"
              type="text"
              v-bng-text-input
            />
          </div>
          
          <FilterDropdown 
            :filters="vehicleShoppingStore.filters"
            @add-filter="handleAddFilter"
            @remove-filter="removeFilter"
            @clear-filters="vehicleShoppingStore.clearAllFilters()"
          />

          <SortDropdown />
        </div>
    </div>

    <!-- Main Content -->
    <div ref="mainContentRef" class="main-content" bng-nav-scroll bng-nav-scroll-force>

      <!-- Show current seller vehicles when at specific dealer -->
      <div v-if="vehicleShoppingStore?.vehicleShoppingData?.currentSeller">
        <!-- Current dealership hero card at the top -->
        <div class="current-dealer-hero">
          <div
            class="hero-preview"
            :style="{ backgroundImage: dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller]?.preview ? `url('${dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller].preview}')` : '' }"
          ></div>
          <div class="hero-content">
            <div class="hero-header">
              <div class="hero-icon"><BngIcon :type="icons.locationSource" /></div>
              <div class="hero-info">
                <h4 class="hero-name">{{ vehicleShoppingStore?.vehicleShoppingData?.currentSellerNiceName }}</h4>
                <p class="hero-description">{{ dealerMetadata[vehicleShoppingStore?.vehicleShoppingData?.currentSeller]?.description || 'Vehicle dealership' }}</p>
              </div>
            </div>
            <div v-if="getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller)" class="hero-rep">
              <div class="rep-bar">
                <div class="rep-fill" :style="{ width: getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).percentage + '%' }"></div>
                <div class="rep-text-inside">
                  <span class="rep-level">Level {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).level }}</span>
                  <span class="rep-message" v-if="getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext > 0">
                    {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext }} more
                  </span>
                  <span class="rep-message" v-else>Max</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Controls removed for cleaner dealership view -->

        <div class="price-notice">
          <span>*&nbsp;</span>
          <span>Additional taxes and fees are applicable</span>
        </div>

        <!-- No vehicles at this dealership -->
        <div v-if="displayedVehicles.length === 0" class="empty-state">
          <BngIcon :type="icons.cars" class="empty-icon" />
          <h4 class="empty-title">No vehicles available</h4>
          <p class="empty-description">
            {{ vehicleShoppingStore?.vehicleShoppingData?.currentSellerNiceName || 'This dealership' }} currently has no vehicles in stock.
          </p>
        </div>

        <!-- Vehicles with pagination -->
        <template v-else>
          <div v-if="totalPages > 1" class="pagination-toolbar">
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
            <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
          </div>
          <div class="vehicle-listings">
            <VehicleCard v-for="(vehicle, key) in pageSlice(displayedVehicles)" :key="key"
              :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle" />
          </div>
          <div v-if="totalPages > 1" class="pagination-toolbar">
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
            <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
          </div>
        </template>
      </div>

      <!-- Show search results when searching -->
      <div v-else-if="hasActiveSearch">
        <div class="content-header">
          <h3 class="content-title">Search Results</h3>
          <div class="header-right">
            <p class="vehicle-count">{{ allFilteredVehicles.length }} vehicle{{ allFilteredVehicles.length !== 1 ? 's' : '' }} found</p>
            <div class="limit-control">
              <BngSelect v-model.number="itemsPerPage" :options="pageSizeOptions" />
            </div>
          </div>
        </div>
        <div class="price-notice">
          <span>*&nbsp;</span>
          <span>Additional taxes and fees are applicable</span>
        </div>

        <!-- No search results -->
        <div v-if="allFilteredVehicles.length === 0" class="empty-state">
          <BngIcon :type="icons.search" class="empty-icon" />
          <h4 class="empty-title">No search results</h4>
          <p class="empty-description">
            No vehicles match your search for "{{ activeSearchQuery }}". Try adjusting your search terms or filters.
          </p>
        </div>

        <!-- Search results with pagination -->
        <template v-else>
          <div v-if="totalPages > 1" class="pagination-toolbar">
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
            <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
          </div>
          <div class="vehicle-listings">
            <VehicleCard v-for="(vehicle, key) in pageSlice(allFilteredVehicles)" :key="vehicle.uid || vehicle.shopId"
              :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle" />
          </div>
          <div v-if="totalPages > 1" class="pagination-toolbar">
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
            <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
            <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
            <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
          </div>
        </template>
      </div>

      <!-- Show main vehicle list with collapsible dealership section -->
      <div v-else>
        <!-- Dealership Selection (collapsed by default) -->
        <div class="dealership-section" :class="{ collapsed: !dealersOpen }">
          <div class="section-header" @click="dealersOpen = !dealersOpen">
            <div class="header-left">
              <BngIcon :type="dealersOpen ? icons.arrowSmallDown : icons.arrowSmallRight" class="expand-icon" />
              <h3 class="section-title">Available Dealerships</h3>
              <span v-if="hiddenDealers.length > 0" class="hidden-count">
                ({{ visibleDealers.length }} online{{ hiddenDealers.length > 0 ? `, ${hiddenDealers.length} offline` : '' }})
              </span>
            </div>
          </div>

          <div class="dealership-content" v-if="dealersOpen">
            <!-- Visible Dealerships Grid -->
            <div class="dealership-grid" v-if="visibleDealers.length > 0">
              <div
                v-for="dealer in visibleDealers"
                :key="dealer.id"
                class="dealership-card"
                :class="{ 
                  'no-rep': !hasRep(dealer.id),
                  'selected': selectedDealershipId === String(dealer.id)
                }"
                @click.stop="navigateToDealership(dealer.id)"
                @mousedown.stop
              >
                <div
                  class="dealership-background"
                  :style="dealerMetadata[dealer.id]?.preview ? { backgroundImage: `linear-gradient(180deg, rgba(0,0,0,0.9), rgba(0,0,0,0)), url('${dealerMetadata[dealer.id].preview}')` } : {}"
                ></div>
                <div class="dealership-overlay"></div>

                <div class="dealership-body">
                  <div class="top-section">
                    <div class="dealership-header">
                      <div class="dealership-info">
                        <div class="dealership-name">
                          <BngIcon :type="dealerMetadata[dealer.id]?.icon || icons.locationSource" />
                          {{ dealerMetadata[dealer.id]?.name || dealer.name }}
                        </div>
                        <div v-if="dealerMetadata[dealer.id]?.description" class="dealership-description">
                          {{ dealerMetadata[dealer.id].description }}
                        </div>
                      </div>
                    </div>
                  </div>
                  
                  <div class="bottom-section">
                  <div v-if="getRepData(dealer.id)" class="rep-progress">
                    <div class="rep-bar">
                      <div class="rep-fill" :style="{ width: getRepData(dealer.id).percentage + '%' }"></div>
                      <div class="rep-text-inside">
                        <span class="rep-level">Level {{ getRepData(dealer.id).level }}</span>
                        <span class="rep-message" v-if="getRepData(dealer.id).purchasesToNext > 0">
                          {{ getRepData(dealer.id).purchasesToNext }} more
                        </span>
                        <span class="rep-message" v-else>Max</span>
                      </div>
                    </div>
                  </div>
                
                  <!-- Vehicle Thumbnails -->
                  <div v-if="dealer.vehicles.length > 0" class="vehicle-thumbnails">
                    <template v-for="(vehicle, idx) in dealer.vehicles.slice(0, 5)" :key="vehicle.shopId || idx">
                      <div
                        class="vehicle-thumbnail"
                        :style="vehicle.preview ? { backgroundImage: `url('${vehicle.preview}')` } : {}"
                      >
                        <div v-if="idx == 0 && dealer.vehicles.length > 5" class="more-label">
                          +{{ dealer.vehicles.length - 4 }}
                        </div>
                      </div>
                    </template>
                  </div>
                </div>
                </div>
              </div>
            </div>

            <!-- Hidden Dealerships Section -->
            <div v-if="hiddenDealers.length > 0" class="hidden-dealers-section">
              <div class="section-header" @click="hiddenDealersOpen = !hiddenDealersOpen">
                <div class="header-left">
                  <BngIcon :type="hiddenDealersOpen ? icons.arrowSmallDown : icons.arrowSmallRight" class="expand-icon" />
                  <h3 class="section-title">Offline Dealerships</h3>
                  <span class="hidden-count">
                    ({{ hiddenDealers.length }} dealer{{ hiddenDealers.length !== 1 ? 's' : '' }})
                  </span>
                </div>
              </div>

              <div class="dealership-grid" v-if="hiddenDealersOpen">
                <div
                  v-for="dealer in hiddenDealers"
                  :key="dealer.id"
                  class="dealership-card hidden-card"
                  @click="confirmTaxi(dealer.id)"
                  :title="'Not available online. Click to take a taxi to ' + (dealerMetadata[dealer.id]?.name || dealer.name)"
                >
                  <div
                    class="dealership-background"
                    :style="dealerMetadata[dealer.id]?.preview ? { backgroundImage: `linear-gradient(180deg, rgba(0,0,0,0.9), rgba(0,0,0,0)), url('${dealerMetadata[dealer.id].preview}')` } : {}"
                  ></div>
                  <div class="dealership-overlay"></div>

                  <div class="dealership-body">
                    <div class="top-section">
                      <div class="dealership-header">
                        <div class="dealership-info">
                          <div class="dealership-name">
                            <BngIcon :type="dealerMetadata[dealer.id]?.icon || icons.locationSource" />
                            {{ dealerMetadata[dealer.id]?.name || dealer.name }}
                          </div>
                          <div v-if="dealerMetadata[dealer.id]?.description" class="dealership-description">
                            {{ dealerMetadata[dealer.id].description }}
                          </div>
                        </div>
                      </div>

                      <div class="dealership-stats">
                        <div class="route-badge">Taxi</div>
                      </div>
                    </div>
                    <div class="bottom-section">
                    <div v-if="getRepData(dealer.id)" class="rep-progress">
                      <div class="rep-bar">
                        <div class="rep-fill" :style="{ width: getRepData(dealer.id).percentage + '%' }"></div>
                        <div class="rep-text-inside">
                          <span class="rep-level">Level {{ getRepData(dealer.id).level }}</span>
                          <span class="rep-message" v-if="getRepData(dealer.id).purchasesToNext > 0">
                            {{ getRepData(dealer.id).purchasesToNext }} more
                          </span>
                          <span class="rep-message" v-else>Max</span>
                        </div>
                      </div>
                    </div>
                    
                    <!-- Vehicle Thumbnails -->
                    <div v-if="dealer.vehicles.length > 0" class="vehicle-thumbnails">
                      <template v-for="(vehicle, idx) in dealer.vehicles.slice(0, 5)" :key="vehicle.shopId || idx">
                        <div
                          class="vehicle-thumbnail"
                          :style="vehicle.preview ? { backgroundImage: `url('${vehicle.preview}')` } : {}"
                        >
                          <div v-if="idx == 0 && dealer.vehicles.length > 5" class="more-label">
                            +{{ dealer.vehicles.length - 4 }}
                          </div>
                        </div>
                      </template>
                    </div>
                  </div>
                </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Vehicle Listings -->
        <div class="vehicles-section">
          <div ref="vehicleListHeaderRef" class="content-header">
            <h3 class="content-title">{{ selectedDealershipId ? (dealerMetadata[selectedDealershipId]?.name || 'Dealership') + ' Vehicles' : 'All Vehicles' }}</h3>
            <div class="header-right">
              <p class="vehicle-count">
                {{ displayedVehicles.length }} vehicle{{ displayedVehicles.length !== 1 ? 's' : '' }} found
              </p>
              <div class="limit-control">
                <BngSelect v-model.number="itemsPerPage" :options="pageSizeOptions" />
              </div>
            </div>
          </div>
          <div class="price-notice">
            <span>*&nbsp;</span>
            <span>Additional taxes and fees are applicable</span>
          </div>

          <div v-if="displayedVehicles.length === 0" class="empty-state">
            <BngIcon :type="icons.cars" class="empty-icon" />
            <h4 class="empty-title">No vehicles available</h4>
            <p class="empty-description">
              {{ selectedDealershipId ? (dealerMetadata[selectedDealershipId]?.name || 'This dealership') + ' currently has no vehicles in stock.' : 'No vehicles match your current filters.' }}
            </p>
          </div>

          <div v-else class="vehicle-listings">
            <VehicleCard
              v-for="(vehicle, key) in pageSlice(displayedVehicles)"
              :key="key"
              :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
              :vehicle="vehicle"
            />

            <!-- Only show pagination when there are multiple pages -->
            <div v-if="totalPages > 1" class="pagination-toolbar">
              <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
              <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
              <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
              <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
            </div>
          </div>

          <!-- Recently Sold Section -->
          <div v-if="relevantSoldVehicles.length > 0" class="sold-section">
            <div class="sold-header">
              <h4 class="sold-title">Recently Sold</h4>
              <span class="sold-count">{{ relevantSoldVehicles.length }} vehicle{{ relevantSoldVehicles.length !== 1 ? 's' : '' }}</span>
            </div>
            <div class="vehicle-listings">
              <VehicleCard
                v-for="(vehicle, key) in relevantSoldVehicles"
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
                :vehicle="vehicle"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { reactive, onMounted, onBeforeUnmount, ref, computed, watch, nextTick } from "vue"
import { useRouter, useRoute } from "vue-router"
import VehicleCard from "./VehicleCard.vue"
import FilterDropdown from "./FilterDropdown.vue"
import SortDropdown from "./SortDropdown.vue"
import { BngCard, BngButton, ACCENTS, BngInput, BngSelect, BngIcon, icons } from "@/common/components/base"
import { vBngBlur } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { openConfirmation } from "@/services/popup"

import { useUINavScope } from "@/services/uiNav"
useUINavScope("vehicleList")

const vehicleShoppingStore = useVehicleShoppingStore()
const events = useEvents()
const { units } = useBridge()
const router = useRouter()
const route = useRoute()
let onDeltaRef = null
const dealerMetadata = ref({})
const inputFocused = ref(false)
const localSearchQuery = ref('')
const activeSearchQuery = ref('')
const dealersOpen = ref(true)
const itemsPerPage = ref(25)
const pageSizeOptions = [10, 25, 50, 100]
const currentPage = ref(1)
const hiddenDealersOpen = ref(false)
const mainContentRef = ref(null)
const vehicleListHeaderRef = ref(null)

const orgsById = computed(() => (vehicleShoppingStore?.vehicleShoppingData?.organizations) || {})

function getRepData(dealerId) {
  const orgId = dealerMetadata.value[dealerId] && dealerMetadata.value[dealerId].associatedOrganization
  if (!orgId) return null
  const org = orgsById.value[orgId]
  if (!org || !org.reputation) return null

  const level = typeof org.reputation.level === 'number' ? org.reputation.level : 0
  let pct = 0
  let percentage = 0
  let vehiclesToNext = 0
  let purchasesToNext = 0

  const cur = org.reputation.curLvlProgress
  const need = org.reputation.neededForNext

  if (typeof cur === 'number' && typeof need === 'number' && need > 0) {
    pct = Math.max(0, Math.min(1, cur / need))
    percentage = Math.round(pct * 100)
    vehiclesToNext = Math.max(0, need - cur)
    // Each purchase gives 10 reputation, so divide by 10 and round up
    purchasesToNext = Math.ceil(vehiclesToNext / 20)
  }

  return { level, pct, percentage, vehiclesToNext, purchasesToNext }
}

const selectedDealershipId = computed(() => {
  return route.params.selectedSellerId || vehicleShoppingStore.selectedSellerId || null
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

function onSearchFocus() {
  inputFocused.value = true
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onSearchBlur() {
  try { triggerSearch() } catch (_) {}
  try { lua.setCEFTyping(false) } catch (_) {}
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

// Fetch dealership data on component mount
onMounted(async () => {
  const shoppingData = await lua.career_modules_vehicleShopping.getShoppingData()

  if (shoppingData?.dealerships && Array.isArray(shoppingData.dealerships)) {
    dealerMetadata.value = shoppingData.dealerships.reduce((acc, dealer) => {
      if (dealer && dealer.id) acc[dealer.id] = dealer
      return acc
    }, {})
  }

  // Ensure initial snapshot
  try { await vehicleShoppingStore.requestVehicleShoppingData() } catch (e) { /* noop */ }

  // Subscribe to deltas via events
  const onDelta = (delta) => {
    if (vehicleShoppingStore && typeof vehicleShoppingStore.applyShopDelta === 'function') vehicleShoppingStore.applyShopDelta(delta)
  }
  events.on('vehicleShopDelta', onDelta)
  onDeltaRef = onDelta
})

// Notify Lua that UI is open; Lua handles timed refresh internally
onMounted(() => { try { lua.career_modules_vehicleShopping.setShoppingUiOpen(true) } catch (_) {} })

onBeforeUnmount(() => {
  try { lua.career_modules_vehicleShopping.setShoppingUiOpen(false) } catch (_) {}
  // Unsubscribe from deltas if events exposes off
  try {
    if (events && typeof events.off === 'function' && typeof onDeltaRef === 'function') {
      events.off('vehicleShopDelta', onDeltaRef)
    }
  } catch (_) {}
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
  return sortedDealers.value.filter(dealer => !dealer.hidden);
});

const hiddenDealers = computed(() => {
  return sortedDealers.value.filter(dealer => dealer.hidden);
});

// Reset pagination when the list context changes
watch([itemsPerPage, hasActiveSearch], () => {
  currentPage.value = 1
})

// Helper: check if dealer has organization reputation
function hasRep(dealerId) {
  const meta = dealerMetadata.value[dealerId]
  if (!meta || !meta.associatedOrganization) return false
  const org = orgsById.value[meta.associatedOrganization]
  return !!(org && org.reputation)
}


async function taxiToDealer(dealershipId) {
  try {
    console.log('TaxiToDealer called for dealership:', dealershipId)
    await lua.career_modules_vehicleShopping.taxiToDealership(dealershipId)
    console.log('Taxi completed successfully')
  } catch (e) {
    console.error('Failed to taxi to dealership:', e)
    // Show error message to user
    if (typeof ui_message !== 'undefined') {
      ui_message(`Failed to taxi to dealership: ${e.message || 'Unknown error'}`, 5, "vehicleShopping")
    }
  }
}

async function confirmTaxi(dealershipId) {
  try {
    console.log('ConfirmTaxi called for dealership:', dealershipId)

    const price = await lua.career_modules_vehicleShopping.getTaxiPriceToDealership(dealershipId)
    console.log('Taxi price:', price)

    const name = dealerMetadata.value[dealershipId]?.name || 'Dealership'
    console.log('Dealer name:', name)

    // Always show a numeric price using BeamNG formatting (0 shows as 0)
    const priceDisplay = units.beamBucks(Math.max(0, Number(price) || 0))

    // Use the proper BeamNG UI confirmation system like VehicleCard.vue does
    console.log('Using openConfirmation dialog...')
    const res = await openConfirmation("", `Taxi to ${name} for ${priceDisplay}?`, [
      { label: "Yes", value: true, extras: { default: true } },
      { label: "No", value: false, extras: { accent: "secondary" } },
    ])
    console.log('openConfirmation result:', res)

    if (res) {
      console.log('User confirmed, calling taxiToDealer...')
      await taxiToDealer(dealershipId)
    } else {
      console.log('User cancelled taxi')
    }
  } catch (e) {
    console.error('Failed to confirm taxi:', e)
    // If confirmation fails, show an error message
    if (typeof ui_message !== 'undefined') {
      ui_message(`Failed to taxi to dealership: ${e.message || 'Unknown error'}`, 5, "vehicleShopping")
    }
  }
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
  const isDeselecting = selectedDealershipId.value === dealershipId
  
  if (isDeselecting) {
    router.replace({
      name: "vehicleShopping",
      params: {
        screenTag: route.params.screenTag || "buying",
        buyingAvailable: route.params.buyingAvailable || "true",
        marketplaceAvailable: route.params.marketplaceAvailable || "false",
        selectedSellerId: "",
      },
    })
  } else {
    router.replace({
      name: "vehicleShopping",
      params: {
        screenTag: route.params.screenTag || "buying",
        buyingAvailable: route.params.buyingAvailable || "true",
        marketplaceAvailable: route.params.marketplaceAvailable || "false",
        selectedSellerId: dealershipId,
      },
    })
    
    await nextTick()
    if (vehicleListHeaderRef.value) {
      vehicleListHeaderRef.value.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }
}


</script>

<style scoped lang="scss">
.vehicle-shop-wrapper {
  flex: 1 1 auto;
  min-height: 0;
  max-width: 80rem;
  height: 100%;
  display: flex;
  flex-direction: column;
  background: transparent;
  border: none;
  box-shadow: none;
}

// Header Section
.header-section {
  flex: 0 0 auto;
  background: linear-gradient(180deg, 
    rgba(var(--bng-cool-gray-900-rgb), 0.95) 0%, 
    rgba(var(--bng-cool-gray-875-rgb), 0.98) 100%
  );
  backdrop-filter: blur(16px);
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  position: sticky;
  top: 0;
  z-index: 100;
  box-shadow: 
    0 4px 24px rgba(0,0,0,0.4),
    0 1px 0 rgba(255,255,255,0.05) inset;

  .header-content {
    max-width: 80rem;
    margin: 0 auto;
    padding: 1.5rem 1rem;
  }

  .title-section {
    margin-bottom: 1rem;

    .icon-section {
      display: flex;
      align-items: center;
      gap: 0.5rem;

      .garage-icon {
        width: 2rem;
        height: 3rem;
        background: var(--bng-orange);
        border-radius: var(--bng-corners-1);
        display: flex;
        align-items: center;
        justify-content: center;
        color: var(--bng-off-black);
        font-weight: bold;
        font-size: 1.25rem;
      }

      .title-info {
        .garage-name {
          color: var(--bng-off-white);
          font-weight: 500;
          margin: 0;
          font-size: 1rem;
        }

        .page-title {
          color: var(--bng-off-white);
          font-size: 1.25rem;
          font-weight: normal;
          margin: 0;
        }
      }
    }
  }

  .nav-buttons {
    display: flex;
    align-items: center;
    gap: 1rem;
    margin-bottom: 1rem;

    .nav-btn {
      color: var(--bng-orange);
      
      &:hover {
        background: var(--bng-orange-alpha-20);
      }
    }

    .view-tabs {
      display: flex;
      gap: 0.5rem;

      .tab-btn {
        &.active {
          background: var(--bng-orange);
          color: var(--bng-off-black);

          &:hover {
            background: var(--bng-orange-dark);
          }
        }
      }
    }
  }

  .search-filter-bar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 1rem 1.25rem;
    background: rgba(0, 0, 0, 0.2);
    backdrop-filter: blur(8px);
    border-bottom: 1px solid rgba(255, 255, 255, 0.03);

    .search-section {
      position: relative;
      flex: 1 1 auto;
      background: rgba(0, 0, 0, 0.3);
      border: 1px solid rgba(255, 255, 255, 0.08);
      border-radius: 9999px;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      overflow: hidden;
      display: flex;
      align-items: center;

      &:hover {
        background: rgba(0, 0, 0, 0.4);
        border-color: rgba(255, 255, 255, 0.12);
      }

      &:focus-within {
        border-color: var(--bng-orange);
        background: rgba(0, 0, 0, 0.5);
        box-shadow: 
          0 0 0 2px var(--bng-orange-alpha-20),
          0 4px 12px rgba(var(--bng-orange-rgb), 0.15);
      }

      .search-icon {
        position: absolute;
        left: 0.875rem;
        top: 50%;
        transform: translateY(-50%);
        color: var(--bng-cool-gray-400);
        width: 1.125rem;
        height: 1.125rem;
        z-index: 2;
        transition: color 0.2s ease;
        display: flex;
        align-items: center;
        justify-content: center;
      }

      &:focus-within .search-icon {
        color: var(--bng-orange);
      }

      .search-input {
        width: 100%;
        padding: 0.5rem 1rem 0.5rem 2.5rem;
        height: 2.25rem;
        background: transparent;
        border: none;
        border-bottom: none !important;
        box-shadow: none !important;
        color: var(--bng-off-white);
        font-size: 0.8125rem;
        border-radius: 9999px;

        &::placeholder {
          color: var(--bng-cool-gray-500);
          font-weight: 400;
        }

        &:focus {
          outline: none;
        }

        &:focus::placeholder {
          color: var(--bng-cool-gray-600);
        }
      }

      /* Ensure inner BngInput elements have no background/underline */
      :deep(input),
      :deep(.input),
      :deep(.bng-input),
      :deep(.bng-input input) {
        background: transparent !important;
        border: none !important;
        border-bottom: none !important;
        outline: none !important;
        box-shadow: none !important;
      }

      /* Hide underline effects implemented with pseudo-elements */
      :deep(.bng-input)::before,
      :deep(.bng-input)::after,
      :deep(.bng-input input)::before,
      :deep(.bng-input input)::after {
        display: none !important;
        content: none !important;
      }

      /* Kill hover/focus styles and any underline variants */
      :deep(.bng-input:hover),
      :deep(.bng-input input:hover),
      :deep(input:hover) {
        background: transparent !important;
        box-shadow: none !important;
      }

      :deep(.bng-input:focus-within),
      :deep(input:focus) {
        background: transparent !important;
        border: none !important;
        border-bottom: none !important;
        outline: none !important;
        box-shadow: none !important;
      }

      :deep(.bng-input *::before),
      :deep(.bng-input *::after) {
        display: none !important;
        content: none !important;
        box-shadow: none !important;
        border: none !important;
        background: transparent !important;
      }
    }

    .sort-control {
      /* strip outer dropdown chrome */
      :deep(.bng-dropdown),
      :deep(.bng-dropdown__container),
      :deep(.dropdown-container) {
        background: transparent !important;
        border: none !important;
        box-shadow: none !important;
        padding: 0 !important;
      }

      .sort-btn {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.75rem 1rem;
        background: var(--bng-cool-gray-800);
        border: 1px solid var(--bng-cool-gray-600);
        border-radius: var(--bng-corners-1);
        color: var(--bng-off-white);
        cursor: pointer;
        transition: all 0.2s ease;
        font-size: 0.875rem;
        font-weight: 500;
        height: 2.75rem;

        &:hover {
          background: var(--bng-orange-alpha-10);
          border-color: var(--bng-orange-alpha-50);
        }

        &.active {
          border-color: var(--bng-orange);
          background: var(--bng-orange-alpha-10);
        }
      }

      .sort-panel {
        width: 24rem;
        background: var(--bng-cool-gray-900);
        border: 1px solid var(--bng-cool-gray-600);
        border-radius: var(--bng-corners-2);
        box-shadow: 0 8px 24px rgba(0,0,0,0.5);
        padding: 1rem;
      }

      .sort-content {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .sort-fields {
        .section-title {
          font-size: 0.95rem;
          color: var(--bng-cool-gray-100);
          font-weight: 700;
          margin-bottom: 0.5rem;
        }

        .field-options {
          display: flex;
          flex-direction: column;
          gap: 0.25rem;
          max-height: 12rem;
          overflow-y: auto;
        }

        .field-option {
          padding: 0.5rem 0.75rem;
          border-radius: var(--bng-corners-1);
          cursor: pointer;
          transition: background 120ms ease;
          background: var(--bng-cool-gray-800);
          border: 1px solid var(--bng-cool-gray-700);
          font-size: 0.875rem;

          &:hover {
            background: var(--bng-cool-gray-775);
          }

          &.selected {
            background: var(--bng-orange-alpha-20);
            border-color: var(--bng-orange);
            color: var(--bng-orange);
          }
        }
      }

      .sort-direction {
        .section-title {
          font-size: 0.95rem;
          color: var(--bng-cool-gray-100);
          font-weight: 700;
          margin-bottom: 0.5rem;
        }

        .direction-options {
          display: flex;
          gap: 0.5rem;
          margin-bottom: 1rem;

          .direction-btn {
            flex: 1;
          }
        }

        .apply-sort-btn {
          width: 100%;
          background: var(--bng-orange);
          color: var(--bng-off-black);

          &:hover {
            background: var(--bng-orange-dark);
          }
        }
      }

      /* Hide default opener button rendered by dropdown container (left small caret) */
      :deep(.bng-dropdown-opener),
      :deep(.bng-dropdown__opener),
      :deep(.dropdown-opener) {
        display: none !important;
      }
    }

    .limit-control {
      width: 7rem;
      
      :deep(.bng-select) {
        background: rgba(0, 0, 0, 0.3);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 0.5rem;
        height: 2rem;
        
        .bng-select-content {
          background: transparent;
          border: none;
          height: 100%;
          padding: 0;
          
          .label {
            font-size: 0.75rem;
            color: var(--bng-cool-gray-200);
          }
        }
        
        .bng-button {
          background: rgba(255, 255, 255, 0.05);
          border: 1px solid rgba(255, 255, 255, 0.08);
          height: 1.75rem;
          padding: 0.25rem;
          
          &:hover {
            background: rgba(255, 255, 255, 0.1);
          }
        }
      }
    }
  }
}

// Main Content
.main-content {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
  color: var(--bng-off-white);
  padding: 1.5rem;
  max-width: 80rem;
  margin: 0 auto;
  width: 100%;
  
  /* Custom scrollbar */
  &::-webkit-scrollbar {
    width: 8px;
  }
  
  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }
  
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;
    
    &:hover {
      background: rgba(255, 255, 255, 0.15);
    }
  }

  .price-notice {
    display: flex;
    justify-content: flex-end;
    align-items: center;
    padding: 0.5rem 0.75rem;
    margin: 0 0 1rem 0;
    background: rgba(var(--bng-orange-rgb), 0.05);
    border: 1px solid rgba(var(--bng-orange-rgb), 0.1);
    border-radius: 0.5rem;
    color: var(--bng-cool-gray-300);
    font-size: 0.75rem;
    
    span:first-child {
      color: var(--bng-orange);
      font-weight: 700;
      margin-right: 0.25rem;
      font-size: 0.875rem;
    }
  }

  .content-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1.5rem;
    padding-bottom: 0.75rem;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);

    .header-right {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .content-title {
      font-size: 1.5rem;
      font-weight: 600;
      color: white;
      margin: 0;
      text-shadow: 0 2px 4px rgba(0,0,0,0.3);
    }

    .vehicle-count {
      font-size: 0.875rem;
      color: var(--bng-cool-gray-300);
      margin: 0;
      padding: 0.25rem 0.75rem;
      background: rgba(0, 0, 0, 0.2);
      border-radius: 9999px;
      border: 1px solid rgba(255, 255, 255, 0.05);
    }
  }

  .content-subtitle {
    font-size: 0.875rem;
    color: var(--bng-cool-gray-300);
    margin-bottom: 1.25rem;
    padding-left: 0.125rem;
  }

  .current-dealer-hero {
    display: grid;
    grid-template-columns: 1fr 2fr;
    gap: 1rem;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: linear-gradient(135deg,
      rgba(var(--bng-cool-gray-900-rgb), 0.6) 0%,
      rgba(var(--bng-cool-gray-850-rgb), 0.4) 100%
    );
    border-radius: 1rem;
    overflow: hidden;
    padding: 1rem;
    margin-bottom: 1rem;

    .hero-preview {
      min-height: 8rem;
      background-size: cover;
      background-position: center;
      border-radius: 0.75rem;
      background-color: var(--bng-cool-gray-850);
    }

    .hero-content {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;

      .hero-header {
        display: flex;
        gap: 0.75rem;
        align-items: center;
      }
      .hero-icon {
        width: 2.25rem;
        height: 2.25rem;
        border-radius: 0.5rem;
        display: flex;
        align-items: center;
        justify-content: center;
        background: rgba(0, 0, 0, 0.5);
        border: 1px solid rgba(255, 255, 255, 0.1);
        color: var(--bng-orange);
        flex-shrink: 0;
      }
      .hero-name {
        margin: 0;
        font-size: 1.125rem;
        color: white;
      }
      .hero-description {
        margin: 0;
        font-size: 0.8rem;
        color: var(--bng-cool-gray-300);
      }
      .hero-rep {
        margin-top: 0.25rem;
        .rep-bar {
          position: relative;
          height: 1.25rem;
          border-radius: 0.25rem;
          background: rgba(255, 255, 255, 0.08);
          overflow: hidden;
          display: flex;
          align-items: center;
        }
        .rep-fill {
          position: absolute;
          top: 0;
          left: 0;
          height: 100%;
          background: linear-gradient(90deg, var(--bng-orange) 0%, var(--bng-orange-b400) 100%);
          transition: width 0.3s ease;
        }
        .rep-text-inside {
          position: relative;
          z-index: 2;
          padding: 0 0.5rem;
          font-size: 0.7rem;
          font-weight: 700;
          color: white;
          text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
          white-space: nowrap;
          width: 100%;
          display: flex;
          align-items: center;
          justify-content: space-between;
          
          .rep-level {
            flex-shrink: 0;
          }
          
          .rep-message {
            flex-shrink: 0;
            font-size: 0.65rem;
          }
        }
      }
    }
  }
}

// Dealership Section
.dealership-section {
  margin-bottom: 2rem;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  
  &.collapsed {
    background: linear-gradient(135deg, 
      rgba(var(--bng-cool-gray-900-rgb), 0.6) 0%, 
      rgba(var(--bng-cool-gray-850-rgb), 0.4) 100%
    );
    backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 1rem;
    padding: 0;
    box-shadow: 
      0 8px 32px rgba(0,0,0,0.3),
      inset 0 1px 0 rgba(255,255,255,0.03);
    
    .section-header {
      border-radius: 1rem;
      margin-bottom: 0;
    }
  }
  
  &:not(.collapsed) {
    background: linear-gradient(135deg, 
      rgba(var(--bng-cool-gray-900-rgb), 0.6) 0%, 
      rgba(var(--bng-cool-gray-850-rgb), 0.4) 100%
    );
    backdrop-filter: blur(12px);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 1rem;
    padding: 0;
    box-shadow: 
      0 8px 32px rgba(0,0,0,0.3),
      inset 0 1px 0 rgba(255,255,255,0.03);
  }

  .section-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1rem 1.25rem;
    cursor: pointer;
    user-select: none;
    transition: all 0.2s ease;
    border-radius: 1rem 1rem 0 0;
    
    &:hover {
      background: rgba(0, 0, 0, 0.15);
      
      .expand-icon {
        color: var(--bng-orange);
        transform: scale(1.1);
      }
    }

    .header-left {
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }

    .expand-icon {
      width: 1.5rem;
      height: 1.5rem;
      color: var(--bng-cool-gray-300);
      transition: all 0.2s ease;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .dealer-controls {
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }

    .section-title {
      font-size: 1.25rem;
      font-weight: 600;
      color: white;
      margin: 0;
      text-shadow: 0 2px 4px rgba(0,0,0,0.3);
    }

    .show-all-btn {
      background: rgba(var(--bng-orange-rgb), 0.1);
      color: var(--bng-orange);
      border: 1px solid var(--bng-orange-alpha-30);

      &:hover {
        background: var(--bng-orange-alpha-20);
        border-color: var(--bng-orange-alpha-50);
      }
    }
  }

  .dealership-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(20em, 1fr));
    gap: 0.5em;
    padding: 0.5em;
  }

  .dealership-card {
    position: relative;
    height: 14em;
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
    border-radius: var(--bng-corners-2);
    padding: 0;
    cursor: pointer;
    color: var(--bng-off-white-brighter);
    background-color: rgba(0, 0, 0, 0.1);
    background-blend-mode: multiply;
    overflow: hidden;
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: all 0.2s ease;

    &:hover {
      background-color: rgba(0, 0, 0, 0.0);
      border-color: var(--bng-orange);
      transform: translateY(-2px);
      box-shadow: 
        0 4px 12px rgba(0, 0, 0, 0.3),
        0 0 0 1px var(--bng-orange-alpha-30);
    }

    &:active {
      transform: translateY(0);
    }

    &.selected {
      border-color: var(--bng-orange);
      box-shadow: 
        0 0 0 2px var(--bng-orange-alpha-50),
        0 8px 20px rgba(0,0,0,0.3);
    }
    
    &.selected:hover {
      border-color: var(--bng-orange);
      transform: translateY(-2px);
      box-shadow: 
        0 4px 12px rgba(0, 0, 0, 0.3),
        0 0 0 2px var(--bng-orange-alpha-50),
        0 8px 20px rgba(0,0,0,0.3);
    }

    &.hiddenOnline {
      opacity: 0.85;
      filter: grayscale(100%);
      
      &:hover {
        opacity: 1;
        filter: grayscale(0%);
      }
    }

    .dealership-background {
      position: absolute;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      width: 100%;
      height: 100%;
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
      z-index: 0;
      background-color: var(--bng-cool-gray-850);
      background-image: linear-gradient(135deg, var(--bng-cool-gray-800) 0%, var(--bng-cool-gray-850) 100%);
    }

    .dealership-overlay {
      position: absolute;
      inset: 0;
      background: linear-gradient(180deg, rgba(0,0,0,0.9), rgba(0,0,0,0));
      z-index: 1;
    }

    /* Content container with proper z-index */
    .dealership-body {
      position: relative;
      z-index: 2;
      height: 100%;
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      padding: 0.75rem 0 0 0; /* Remove side/bottom padding so thumbnails hit edges */
    }

    .top-section {
      padding: 0 0.75rem; /* Move side padding here */
    }

    .dealership-header {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      width: 100%;
    }

    .dealership-icon {
      display: none; // Hide icon in seller grid style
    }

    .dealership-info {
      width: 100%;
    }

    .dealership-name {
      font-weight: 600;
      font-size: 1.05rem;
      margin-bottom: 0.25rem;
      color: white;
      text-shadow: 0 2px 4px rgba(0,0,0,0.5);
      
      :deep(.icon-base) {
        margin-right: 0.5rem;
      }
    }

    .dealership-description {
      font-size: 0.8rem;
      font-weight: 200;
      padding-top: 0;
      color: rgba(255, 255, 255, 0.9);
      text-shadow: 0 1px 3px rgba(0,0,0,0.5);
    }

    .dealership-stats {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.5rem;
      margin-top: auto;
      padding-top: 0.5rem; // compact

      .vehicle-count-badge {
        padding: 0.25rem 0.5rem;
        background: rgba(0, 0, 0, 0.55);
        backdrop-filter: blur(6px);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 0.375rem;
        color: var(--bng-orange);
        font-weight: 700;
        font-size: 0.8rem;
        line-height: 1;
        text-shadow: 0 1px 2px rgba(0,0,0,0.3);
      }

      .selected-badge {
        padding: 0.25rem 0.5rem;
        background: var(--bng-orange);
        color: var(--bng-off-black);
        border-radius: 0.375rem;
        font-size: 0.7rem;
        font-weight: 700;
        text-transform: uppercase;
        line-height: 1;
      }

      .route-badge {
        padding: 0.25rem 0.5rem;
        background: rgba(0, 0, 0, 0.55);
        backdrop-filter: blur(6px);
        color: var(--bng-orange);
        border: 1px dashed var(--bng-orange);
        border-radius: 0.375rem;
        font-size: 0.7rem;
        font-weight: 700;
        text-transform: uppercase;
        line-height: 1;
      }
    }

    .bottom-section {
      position: relative;
      width: 100%;
      z-index: 3;
      display: flex;
      flex-direction: column;
      justify-content: flex-end;
      margin-top: auto;
    }

    .vehicle-thumbnails {
      position: relative;
      display: flex;
      flex-direction: row;
      flex-flow: row-reverse nowrap;
      align-items: flex-end;
      justify-content: space-around;
      width: 100%;
      gap: 0;
      padding: 0 0.25em;
      background: linear-gradient(to top, rgba(0, 0, 0, 1) 0, rgba(0, 0, 0, 0.8) 2rem, rgba(0, 0, 0, 0) 100%);
      overflow: hidden;
      flex-shrink: 0;

      .vehicle-thumbnail {
        width: 4.8em;
        gap: 5px;
        height: auto;
        aspect-ratio: 16 / 9;
        border-radius: var(--bng-corners-1);
        background-size: cover;
        background-position: center;
        background-repeat: no-repeat;
        background-color: var(--bng-cool-gray-800);
        overflow: hidden;
        flex-shrink: 0;
        position: relative;

        .more-label {
          width: 100%;
          height: 100%;
          display: flex;
          align-items: center;
          justify-content: center;
          background-color: rgba(0, 0, 0, 0.75);
          color: white;
          font-size: 1.25rem;
          font-weight: 500;
        }
      }
    }

    &.hidden-card {
      opacity: 0.85;

      &:hover {
        opacity: 1;
        background-color: rgba(0, 0, 0, 0.0);
        border-color: var(--bng-orange);
        transform: translateY(-2px);
        box-shadow: 
          0 4px 12px rgba(0, 0, 0, 0.3),
          0 0 0 1px var(--bng-orange-alpha-30);
      }

      .dealership-preview {
        filter: grayscale(0.3);
      }

      .dealership-info {
        max-width: 75%;
      }

      .dealership-name {
        color: var(--bng-off-white);
        font-weight: 800;
        text-shadow: 0 2px 8px rgba(0,0,0,0.75);
      }

      .dealership-description {
        color: var(--bng-cool-gray-150);
        text-shadow: 0 1px 6px rgba(0,0,0,0.75);
      }

      .vehicle-count-badge.offline {
        background: rgba(0, 0, 0, 0.4);
        color: var(--bng-cool-gray-400);
        border-color: rgba(255, 255, 255, 0.05);
      }

      .route-badge {
        opacity: 1;
        background: rgba(var(--bng-orange-rgb), 0.1);
        border-color: var(--bng-orange-alpha-50);
        color: var(--bng-orange);
      }
    }

    .rep-progress {
      position: relative;
      width: 100%;
      padding: 0 0.25rem;
      height: 1.25rem;
      z-index: 4;
      margin-bottom: 5px;
      flex-shrink: 0;
      
      .rep-bar {
        position: relative;
        height: 1.25rem;
        border-radius: 0.25rem;
        background: rgba(255, 255, 255, 0.08);
        overflow: hidden;
        display: flex;
        align-items: center;
      }
      
      .rep-fill {
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background: linear-gradient(90deg, var(--bng-orange) 0%, var(--bng-orange-b400) 100%);
        transition: width 0.3s ease;
      }
      
      .rep-text-inside {
        position: relative;
        z-index: 2;
        padding: 0 0.5rem;
        font-size: 0.7rem;
        font-weight: 700;
        color: white;
        text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
        white-space: nowrap;
        width: 100%;
        display: flex;
        align-items: center;
        justify-content: space-between;
        
        .rep-level {
          flex-shrink: 0;
        }
        
        .rep-message {
          flex-shrink: 0;
          font-size: 0.65rem;
        }
      }
    }

    /* For cards without organization reputation */
    &.no-rep {
      .rep-placeholder {
        margin-top: 0.25rem;
        color: var(--bng-cool-gray-300);
        font-size: 0.75rem;
        font-style: italic;
      }
    }
  }
}

// Vehicle Listings
.vehicle-listings {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 0.5rem 0;
}

.pagination-bar {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  padding: 0.75rem 0 1rem 0;
}
.pagination-bar .pagination-info {
  color: var(--bng-cool-gray-300);
  font-size: 0.875rem;
}

.pagination-toolbar {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.75rem;
  padding: 1.25rem 0;
  margin-top: 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.05);
}
.pagination-toolbar .pagination-info {
  color: var(--bng-cool-gray-200);
  font-size: 0.875rem;
  padding: 0.25rem 0.625rem;
  background: rgba(0, 0, 0, 0.2);
  border-radius: 0.375rem;
  border: 1px solid rgba(255, 255, 255, 0.05);
}
.pagination-toolbar .page-btn {
  min-width: 5rem;
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.08);
  
  &:hover:not(:disabled) {
    background: rgba(0, 0, 0, 0.4);
    border-color: var(--bng-orange-alpha-50);
  }
  
  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

// Dealer Sections (when showing all)
.dealer-section {
  margin-bottom: 2rem;

  .dealer-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
    padding: 0.75rem;
    background: var(--bng-cool-gray-900);
    border-radius: var(--bng-corners-2);
    border: 1px solid var(--bng-cool-gray-700);

    .dealer-title-section {
      display: flex;
      align-items: center;
      gap: 0.75rem;

      .dealer-preview-small {
        width: 3rem;
        height: 2.25rem;
        background-size: cover;
        background-position: center;
        background-repeat: no-repeat;
        border-radius: var(--bng-corners-1);
      }

      .dealer-section-name {
        font-size: 1.125rem;
        font-weight: 600;
        color: var(--bng-off-white);
        margin: 0;
      }

      .dealer-section-description {
        font-size: 0.875rem;
        color: var(--bng-cool-gray-300);
        margin: 0;
      }
    }

    .dealer-vehicle-count {
      color: var(--bng-cool-gray-300);
      font-weight: 300;
    }
  }

  .dealer-vehicles {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
    padding-left: 0;
  }
}

// Empty State
.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 5rem 2rem;
  text-align: center;
  background: linear-gradient(135deg, 
    rgba(var(--bng-cool-gray-900-rgb), 0.4) 0%, 
    rgba(var(--bng-cool-gray-850-rgb), 0.3) 100%
  );
  backdrop-filter: blur(8px);
  border-radius: 1rem;
  border: 1px solid rgba(255, 255, 255, 0.05);
  box-shadow: 
    0 8px 32px rgba(0,0,0,0.2),
    inset 0 1px 0 rgba(255,255,255,0.02);

  .empty-icon {
    width: 5rem;
    height: 5rem;
    color: var(--bng-cool-gray-400);
    margin-bottom: 1.5rem;
    opacity: 0.7;
  }

  .empty-title {
    font-size: 1.25rem;
    font-weight: 600;
    margin: 0 0 0.75rem 0;
    color: white;
    text-shadow: 0 2px 4px rgba(0,0,0,0.3);
  }

  .empty-description {
    font-size: 0.875rem;
    color: var(--bng-cool-gray-300);
    margin: 0;
    max-width: 450px;
    line-height: 1.5;
  }

  .hidden-count {
    font-size: 0.75rem;
    color: var(--bng-cool-gray-400);
    margin-left: 0.5rem;
  }

  .dealership-content {
    margin-top: 0.5rem;
  }

  .hidden-dealers-section {
    margin-top: 1.5rem;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
    padding-top: 1rem;

    .section-header {
      margin-bottom: 0.5rem;
    }

    .dealership-grid {
      margin-top: 0.5rem;
    }
  }
}

// Sold Section
.sold-section {
  margin-top: 2rem;
  padding-top: 1.5rem;
  border-top: 1px solid rgba(255, 255, 255, 0.05);

  .sold-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 1rem;
  }

  .sold-title {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--bng-cool-gray-300);
    margin: 0;
  }

  .sold-count {
    font-size: 0.75rem;
    color: var(--bng-cool-gray-500);
    padding: 0.25rem 0.5rem;
    background: rgba(0, 0, 0, 0.2);
    border-radius: 9999px;
    border: 1px solid rgba(255, 255, 255, 0.05);
  }
  
  /* Make sold cards look a bit different/dimmed */
  :deep(.vehicle-card) {
    opacity: 0.85;
    filter: grayscale(0.4);
    
    &:hover {
      opacity: 1;
      filter: grayscale(0);
    }
  }
}
</style>

