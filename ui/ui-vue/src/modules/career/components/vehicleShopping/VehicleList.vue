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
    <div class="main-content" bng-nav-scroll bng-nav-scroll-force>

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
              </div>
              <div class="rep-details">
                <div class="rep-label">Level {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).level }}</div>
                <div class="rep-percentage">{{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).percentage }}%</div>
                <div class="rep-purchases-needed" v-if="getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext > 0">
                  {{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext }} purchase{{ getRepData(vehicleShoppingStore?.vehicleShoppingData?.currentSeller).purchasesToNext !== 1 ? 's' : '' }} to next level
                </div>
                <div class="rep-max-level" v-else>Max level</div>
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
        <div v-if="vehicleShoppingStore.filteredVehicles.length === 0" class="empty-state">
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
            <VehicleCard v-for="(vehicle, key) in pageSlice(vehicleShoppingStore.filteredVehicles)" :key="key"
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

      <!-- Show dealership selection and grouped vehicles -->
      <div v-else>
        <!-- Dealership Selection -->
        <div class="dealership-section" :class="{ collapsed: !dealersOpen }">
          <div class="section-header" @click="dealersOpen = !dealersOpen">
            <div class="header-left">
              <BngIcon :type="dealersOpen ? icons.arrowSmallDown : icons.arrowSmallRight" class="expand-icon" />
              <h3 class="section-title">Available Dealerships</h3>
              <span v-if="hiddenDealers.length > 0" class="hidden-count">
                ({{ visibleDealers.length }} online{{ hiddenDealers.length > 0 ? `, ${hiddenDealers.length} offline` : '' }})
              </span>
            </div>
            <div class="dealer-controls">
              <BngButton v-if="selectedDealership" :accent="ACCENTS.menu" @click.stop="selectedDealership = null" class="show-all-btn">
                Show All Dealerships
              </BngButton>
            </div>
          </div>

          <div class="dealership-content" v-if="dealersOpen">
            <!-- Visible Dealerships Grid -->
            <div class="dealership-grid" v-if="visibleDealers.length > 0">
              <div
                v-for="dealer in visibleDealers"
                :key="dealer.id"
                class="dealership-card"
                :class="{ selected: selectedDealership === dealer.id, 'no-rep': !hasRep(dealer.id) }"
                @click="handleDealershipSelect(dealer.id)"
              >
                <div v-if="dealerMetadata[dealer.id]?.preview" class="dealership-preview"
                  :style="{ backgroundImage: `url('${dealerMetadata[dealer.id].preview}')` }"></div>
                <div v-else class="dealership-preview"></div>

                <div class="dealership-content">
                  <div class="dealership-header">
                    <div class="dealership-icon">
                      <BngIcon :type="icons.locationSource" />
                    </div>
                    <div class="dealership-info">
                      <h4 class="dealership-name">{{ dealerMetadata[dealer.id]?.name || dealer.name }}</h4>
                      <p class="dealership-description">
                        {{ dealerMetadata[dealer.id]?.description || 'Vehicle dealership' }}
                      </p>
                    </div>
                  </div>

                  <div class="dealership-stats">
                    <span class="vehicle-count-badge">
                      {{ dealer.vehicles.length > 0 ? `${dealer.vehicles.length} Available` : 'No vehicles' }}
                    </span>
                    <div v-if="selectedDealership === dealer.id" class="selected-badge">Selected</div>
                  </div>
                  <div v-if="getRepData(dealer.id)" class="rep-progress">
                    <div class="rep-bar">
                      <div class="rep-fill" :style="{ width: getRepData(dealer.id).percentage + '%' }"></div>
                    </div>
                    <div class="rep-details">
                      <div class="rep-label">Level {{ getRepData(dealer.id).level }}</div>
                      <div class="rep-percentage">{{ getRepData(dealer.id).percentage }}%</div>
                      <div class="rep-purchases-needed" v-if="getRepData(dealer.id).purchasesToNext > 0">
                        {{ getRepData(dealer.id).purchasesToNext }} purchase{{ getRepData(dealer.id).purchasesToNext !== 1 ? 's' : '' }} to next level
                      </div>
                      <div class="rep-max-level" v-else>Max level</div>
                    </div>
                  </div>
                  <div v-else class="rep-placeholder">Independent seller</div>
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
                <div class="dealer-controls">
                  <!-- Can add controls here if needed -->
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
                  <div v-if="dealerMetadata[dealer.id]?.preview" class="dealership-preview"
                    :style="{ backgroundImage: `url('${dealerMetadata[dealer.id].preview}')` }"></div>
                  <div v-else class="dealership-preview"></div>

                  <div class="dealership-content">
                    <div class="dealership-header">
                      <div class="dealership-icon">
                        <BngIcon :type="icons.locationSource" />
                      </div>
                      <div class="dealership-info">
                        <h4 class="dealership-name">{{ dealerMetadata[dealer.id]?.name || dealer.name }}</h4>
                        <p class="dealership-description">
                          {{ dealerMetadata[dealer.id]?.description || 'Vehicle dealership' }}
                        </p>
                      </div>
                    </div>

                    <div class="dealership-stats">
                      <span class="vehicle-count-badge offline">
                        Visit location
                      </span>
                      <div class="route-badge">Taxi</div>
                    </div>
                    <div v-if="getRepData(dealer.id)" class="rep-progress">
                      <div class="rep-bar">
                        <div class="rep-fill" :style="{ width: getRepData(dealer.id).percentage + '%' }"></div>
                      </div>
                      <div class="rep-details">
                        <div class="rep-label">Level {{ getRepData(dealer.id).level }}</div>
                        <div class="rep-percentage">{{ getRepData(dealer.id).percentage }}%</div>
                        <div class="rep-purchases-needed" v-if="getRepData(dealer.id).purchasesToNext > 0">
                          {{ getRepData(dealer.id).purchasesToNext }} purchase{{ getRepData(dealer.id).purchasesToNext !== 1 ? 's' : '' }} to next level
                        </div>
                        <div class="rep-max-level" v-else>Max level</div>
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
          <div class="content-header">
            <h3 class="content-title">
              {{ selectedDealership ? `${(dealerMetadata[selectedDealership]?.name || selectedDealership)} - Vehicles` : 'All Vehicles' }}
            </h3>
            <div class="header-right">
              <p class="vehicle-count">
                {{ selectedDealership ? filteredVehicleCount : vehicleShoppingStore.filteredVehicles.length }} vehicle{{ (selectedDealership ? filteredVehicleCount : vehicleShoppingStore.filteredVehicles.length) !== 1 ? 's' : '' }} found
              </p>
              <div v-if="!selectedDealership" class="limit-control">
                <BngSelect v-model.number="itemsPerPage" :options="pageSizeOptions" />
              </div>
            </div>
          </div>
          <div class="price-notice">
            <span>*&nbsp;</span>
            <span>Additional taxes and fees are applicable</span>
          </div>
          <div v-if="selectedDealership" class="content-subtitle">
            Showing vehicles from {{ dealerMetadata[selectedDealership]?.name || selectedDealership }}
          </div>

          <div v-if="filteredVehicleCount === 0" class="empty-state">
            <BngIcon :type="icons.cars" class="empty-icon" />
            <h4 class="empty-title">No vehicles available</h4>
            <p class="empty-description">
              {{ selectedDealership 
                ? `${dealerMetadata[selectedDealership]?.name || selectedDealership} currently has no vehicles in stock.`
                : 'No vehicles match your current filters.' 
              }}
            </p>
          </div>

          <div v-else class="vehicle-listings">
            <template v-if="selectedDealership">
              <VehicleCard
                v-for="(vehicle, key) in pageSlice(getSelectedDealerVehicles())"
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
                :vehicle="vehicle"
              />
            </template>
            <template v-else>
              <VehicleCard
                v-for="(vehicle, key) in pageSlice(vehicleShoppingStore.filteredVehicles)"
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData"
                :vehicle="vehicle"
              />
            </template>

            <!-- Only show pagination when there are multiple pages -->
            <div v-if="totalPages > 1" class="pagination-toolbar">
              <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage <= 1" @click="currentPage = Math.max(1, currentPage - 1)">Prev</BngButton>
              <span class="pagination-info">{{ pageStart }}–{{ pageEnd }} of {{ totalItems }}</span>
              <span class="pagination-info">Page {{ currentPage }} / {{ totalPages }}</span>
              <BngButton :accent="ACCENTS.primary" class="page-btn" :disabled="currentPage >= totalPages" @click="currentPage = Math.min(totalPages, currentPage + 1)">Next</BngButton>
            </div>
          </div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { reactive, onMounted, onBeforeUnmount, ref, computed, watch } from "vue"
import VehicleCard from "./VehicleCard.vue"
import FilterDropdown from "./FilterDropdown.vue"
import SortDropdown from "./SortDropdown.vue"
import { BngCard, BngButton, ACCENTS, BngBinding, BngInput, BngSelect, BngDropdownContainer, BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngOnUiNav } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { Accordion, AccordionItem } from "@/common/components/utility"
import { openConfirmation } from "@/services/popup"

import { useUINavScope } from "@/services/uiNav"
useUINavScope("vehicleList")

const vehicleShoppingStore = useVehicleShoppingStore()
const events = useEvents()
const { units } = useBridge()
let onDeltaRef = null
const dealerMetadata = ref({})
const inputFocused = ref(false)
const localSearchQuery = ref('')
const activeSearchQuery = ref('')
const sortOpen = ref(false)
const sortFieldLocal = ref('Value')
const sortDirectionLocal = ref('Ascending')
const selectedDealership = ref(null)
const dealersOpen = ref(true)
const itemsPerPage = ref(25)
const pageSizeOptions = [10, 25, 50, 100]
const currentPage = ref(1)

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
    purchasesToNext = Math.ceil(vehiclesToNext / 10)
  }

  return { level, pct, percentage, vehiclesToNext, purchasesToNext }
}

const totalItems = computed(() => {
  if (selectedDealership.value) return getSelectedDealerVehicles().length
  if (hasActiveSearch.value) return allFilteredVehicles.value.length
  return vehicleShoppingStore.filteredVehicles.length
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

  // Otherwise collect vehicles from all dealers
  vehicleShoppingStore.vehiclesByDealer.forEach(dealer => {
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

const getWebsiteText = () => {
  const headerText = getHeaderText()
  return headerText.replace(/\s+/g, "-") + ".com"
}

const layouts = reactive([
  { name: "switch", selected: true, class: "" },
  { name: "me", selected: false, class: "" },
  { name: "please", selected: false, class: "" },
])
function switchLayout(key) {
  for (let i = 0; i < layouts.length; i++) layouts[i].selected = key === i
}

const onDealerExpanded = (dealer, state) => {
  dealer.expanded = state
}

const sortedDealers = computed(() => {
  // Include all dealers (hidden ones are marked with hidden: true)
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

const hiddenDealersOpen = ref(false);

// Reset pagination when the list context changes
watch([itemsPerPage, selectedDealership, hasActiveSearch], () => {
  currentPage.value = 1
})

// Hidden dealer logic is now handled in the store and provided via dealer.hidden property

// Helper: check if dealer has organization reputation
function hasRep(dealerId) {
  const meta = dealerMetadata.value[dealerId]
  if (!meta || !meta.associatedOrganization) return false
  const org = orgsById.value[meta.associatedOrganization]
  return !!(org && org.reputation)
}

// Route to dealership in-world when hidden online
async function routeToDealer(dealershipId) {
  try {
    await lua.career_modules_vehicleShopping.navigateToDealership(dealershipId)
  } catch (e) {
    console.error('Failed to set route to dealership', e)
  }
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
function applySort() {
  const dir = sortDirectionLocal.value === 'Descending' ? 'desc' : 'asc'
  vehicleShoppingStore.setSort(sortFieldLocal.value || 'Value', dir)
}

function formatFieldLabel(key) {
  if (!key) return ''
  return key
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/^./, s => s.toUpperCase())
}

// Keep only the functions we still need

// Handle dealership selection
const handleDealershipSelect = (dealershipId) => {
  selectedDealership.value = selectedDealership.value === dealershipId ? null : dealershipId
}

// Get vehicles for selected dealership
const getSelectedDealerVehicles = () => {
  if (!selectedDealership.value) return []
  const dealer = sortedDealers.value.find(d => d.id === selectedDealership.value)
  return dealer ? dealer.vehicles : []
}

// Count filtered vehicles
const filteredVehicleCount = computed(() => {
  if (selectedDealership.value) {
    return getSelectedDealerVehicles().length
  }
  return sortedDealers.value.reduce((total, dealer) => total + dealer.vehicles.length, 0)
})
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
          height: 8px;
          border-radius: 9999px;
          background: rgba(255, 255, 255, 0.08);
          overflow: hidden;
        }
        .rep-fill {
          height: 100%;
          background: linear-gradient(90deg, var(--bng-orange) 0%, var(--bng-orange-b400) 100%);
        }
        .rep-details {
          margin-top: 0.25rem;
          display: flex;
          justify-content: space-between;
          align-items: center;
          font-size: 0.8rem;
        }
        .rep-label {
          color: var(--bng-cool-gray-200);
          font-weight: 600;
        }
        .rep-percentage {
          color: var(--bng-orange);
          font-weight: 700;
          font-size: 0.85rem;
        }
        .rep-purchases-needed {
          color: var(--bng-cool-gray-300);
          font-size: 0.75rem;
          text-align: right;
        }
        .rep-max-level {
          color: var(--bng-orange);
          font-size: 0.75rem;
          font-weight: 600;
          text-align: right;
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
    grid-template-columns: repeat(3, 1fr);
    gap: 1.25rem;
    padding: 1.5rem;
    padding-top: 0.5rem;
  }

  .dealership-card {
    position: relative;
    min-height: 10rem;
    background: var(--bng-cool-gray-900);
    border: 1px solid var(--bng-cool-gray-700);
    border-radius: 0.75rem;
    cursor: pointer;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    overflow: hidden;

    &:hover {
      border-color: var(--bng-orange-b400);
      transform: translateY(-3px);
      box-shadow: 
        0 10px 25px rgba(0,0,0,0.4),
        0 0 40px rgba(var(--bng-orange-rgb), 0.1);
    }

    &.selected {
      border-color: var(--bng-orange);
      box-shadow: 
        0 0 0 2px var(--bng-orange-alpha-50),
        0 8px 20px rgba(0,0,0,0.3);
    }

    &.hiddenOnline {
      opacity: 0.85;
      
      .dealership-preview {
        filter: grayscale(0.5);
      }
    }

    .dealership-preview {
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
      
      /* Default fallback gradient if no image */
      background-color: var(--bng-cool-gray-850);
      background-image: linear-gradient(135deg, var(--bng-cool-gray-800) 0%, var(--bng-cool-gray-850) 100%);
    }

    /* Dark overlay gradient for text readability */
    .dealership-preview::after {
      content: '';
      position: absolute;
      inset: 0;
      background: linear-gradient(
        180deg,
        rgba(0, 0, 0, 0.3) 0%,
        rgba(0, 0, 0, 0.5) 50%,
        rgba(0, 0, 0, 0.85) 100%
      );
      z-index: 1;
    }

    /* Content container with proper z-index */
    .dealership-content {
      position: relative;
      z-index: 2;
      height: 100%;
      min-height: 10rem;
      padding: 1.25rem 1.25rem 0.5rem 1.25rem; // Reduced bottom padding from 1.25rem to 0.75rem
      display: flex;
      flex-direction: column;
      justify-content: space-between;
    }

    .dealership-header {
      display: flex;
      align-items: flex-start;
      gap: 0.75rem;
    }

    .dealership-icon {
      width: 2.5rem;
      height: 2.5rem;
      border-radius: 0.5rem;
      display: flex;
      align-items: center;
      justify-content: center;
      background: rgba(0, 0, 0, 0.5);
      backdrop-filter: blur(8px);
      border: 1px solid rgba(255, 255, 255, 0.1);
      color: var(--bng-orange);
      flex-shrink: 0;
    }

    &.selected .dealership-icon {
      background: var(--bng-orange);
      color: var(--bng-off-black);
      border-color: var(--bng-orange);
    }

    .dealership-info {
      flex: 1;
      min-width: 0;
    }

    .dealership-name {
      font-size: 1.125rem;
      font-weight: 600;
      margin: 0 0 0.25rem 0;
      color: white;
      text-shadow: 0 2px 4px rgba(0,0,0,0.5);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .dealership-description {
      font-size: 0.75rem;
      color: rgba(255, 255, 255, 0.85);
      margin: 0;
      text-shadow: 0 1px 3px rgba(0,0,0,0.5);
      overflow: hidden;
      text-overflow: ellipsis;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      line-height: 1.4;
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

    &.hidden-card {
      opacity: 0.85;

      &:hover {
        opacity: 1;
        border-color: var(--bng-orange);
        transform: translateY(-3px);
        box-shadow:
          0 10px 25px rgba(0,0,0,0.4),
          0 0 40px rgba(var(--bng-orange-rgb), 0.1);
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
      margin-top: 0.25rem; // Reduced from 0.5rem to 0.25rem for more compact layout
      .rep-bar {
        position: relative;
        height: 6px;
        border-radius: 9999px;
        background: rgba(255, 255, 255, 0.08);
        overflow: hidden;
      }
      .rep-fill {
        height: 100%;
        background: linear-gradient(90deg, var(--bng-orange) 0%, var(--bng-orange-b400) 100%);
      }
      .rep-details {
        margin-top: 0.2rem;
        display: grid;
        grid-template-columns: auto 1fr auto;
        align-items: center;
        column-gap: 0.5rem;
        font-size: 0.7rem;
      }
      .rep-label {
        color: var(--bng-cool-gray-300);
        font-weight: 600;
      }
      .rep-percentage {
        color: var(--bng-orange);
        font-weight: 700;
        font-size: 0.75rem;
        white-space: nowrap;
      }
      .rep-purchases-needed {
        color: var(--bng-cool-gray-400);
        font-size: 0.65rem;
        text-align: right;
      }
      .rep-max-level {
        color: var(--bng-orange);
        font-size: 0.65rem;
        font-weight: 600;
        text-align: right;
        white-space: nowrap;
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
  gap: 0.75rem;
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
</style>

<style lang="scss">
/* Global overrides for teleported dropdown panels to prevent scrollbars */
.bng-dropdown,
.bng-dropdown__container,
.dropdown-container,
.bng-dropdown-content,
.bng-dropdown__content,
.dropdown-content,
.bng-dropdown-panel,
.bng-dropdown__panel,
.dropdown-panel {
  max-height: none !important;
  overflow: visible !important;
}
</style>
