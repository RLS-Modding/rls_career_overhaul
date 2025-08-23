<template>
  <BngCard class="vehicle-shop-wrapper" v-bng-blur bng-ui-scope="vehicleList">
    <!-- Header Section -->
    <div class="header-section">
        <!-- Search and Filter Bar -->
        <div class="search-filter-bar">
          <div class="search-section">
            <BngIcon :type="icons.search" class="search-icon" />
            <BngInput 
              v-model="localSearchQuery" 
              placeholder="Search for a vehicle..." 
              @focus="inputFocused = true"
              @blur="triggerSearch" 
              @keydown.enter="triggerSearch" 
              class="search-input"
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
      <div class="price-notice">
        <span>*&nbsp;</span>
        <span>Additional taxes and fees are applicable</span>
      </div>

      <!-- Show current seller vehicles when at specific dealer -->
      <div v-if="vehicleShoppingStore?.vehicleShoppingData?.currentSeller">
        <div class="content-header">
          <h3 class="content-title">{{ vehicleShoppingStore?.vehicleShoppingData?.currentSellerNiceName || 'Dealership' }} - Vehicles</h3>
          <p class="vehicle-count">{{ vehicleShoppingStore.filteredVehicles.length }} vehicle{{ vehicleShoppingStore.filteredVehicles.length !== 1 ? 's' : '' }} found</p>
        </div>
        <div class="vehicle-listings">
          <VehicleCard v-for="(vehicle, key) in vehicleShoppingStore.filteredVehicles" :key="key"
            :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle" />
        </div>
      </div>

      <!-- Show search results when searching -->
      <div v-else-if="hasActiveSearch">
        <div class="content-header">
          <h3 class="content-title">Search Results</h3>
          <p class="vehicle-count">{{ allFilteredVehicles.length }} vehicle{{ allFilteredVehicles.length !== 1 ? 's' : '' }} found</p>
        </div>
        <div class="vehicle-listings">
          <VehicleCard v-for="(vehicle, key) in allFilteredVehicles" :key="vehicle.shopId"
            :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" :vehicle="vehicle" />
        </div>
      </div>

      <!-- Show dealership selection and grouped vehicles -->
      <div v-else>
        <!-- Dealership Selection -->
        <div class="dealership-section">
          <div class="section-header">
            <h3 class="section-title">Available Dealerships</h3>
            <BngButton v-if="selectedDealership" :accent="ACCENTS.menu" @click="selectedDealership = null" class="show-all-btn">
              Show All Dealerships
            </BngButton>
          </div>
          <div class="dealership-grid">
            <div 
              v-for="dealer in sortedDealers" 
              :key="dealer.id" 
              class="dealership-card" 
              :class="{ selected: selectedDealership === dealer.id }"
              @click="handleDealershipSelect(dealer.id)"
            >
              <div class="dealership-icon">
                <BngIcon :type="icons.locationSource" />
              </div>
              <h4 class="dealership-name">{{ dealerMetadata[dealer.id]?.name || dealer.name }}</h4>
              <p class="dealership-description">{{ dealerMetadata[dealer.id]?.description || 'Vehicle dealership' }}</p>
              <div class="dealership-stats">
                <span class="vehicle-count-badge">
                  {{ dealer.vehicles.length > 0 ? `${dealer.vehicles.length} Available` : 'No vehicles available' }}
                </span>
                <div v-if="selectedDealership === dealer.id" class="selected-badge">Selected</div>
              </div>
              <div v-if="dealerMetadata[dealer.id]?.preview" class="dealership-preview"
                :style="{ backgroundImage: `url('${dealerMetadata[dealer.id].preview}')` }"></div>
            </div>
          </div>
        </div>

        <!-- Vehicle Listings -->
        <div class="vehicles-section">
          <div class="content-header">
            <h3 class="content-title">
              {{ selectedDealership ? `${(dealerMetadata[selectedDealership]?.name || selectedDealership)} - Vehicles` : 'All Vehicles' }}
            </h3>
            <p class="vehicle-count">
              {{ selectedDealership ? filteredVehicleCount : vehicleShoppingStore.filteredVehicles.length }} vehicle{{ (selectedDealership ? filteredVehicleCount : vehicleShoppingStore.filteredVehicles.length) !== 1 ? 's' : '' }} found
            </p>
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
                v-for="(vehicle, key) in getSelectedDealerVehicles()" 
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" 
                :vehicle="vehicle" 
              />
            </template>
            <template v-else>
              <VehicleCard 
                v-for="(vehicle, key) in vehicleShoppingStore.filteredVehicles" 
                :key="key"
                :vehicleShoppingData="vehicleShoppingStore.vehicleShoppingData" 
                :vehicle="vehicle" 
              />
            </template>
          </div>
        </div>
      </div>
    </div>
  </BngCard>
</template>

<script setup>
import { reactive, onMounted, ref, computed } from "vue"
import VehicleCard from "./VehicleCard.vue"
import FilterDropdown from "./FilterDropdown.vue"
import SortDropdown from "./SortDropdown.vue"
import { BngCard, BngButton, ACCENTS, BngBinding, BngInput, BngSelect, BngDropdownContainer, BngIcon, icons } from "@/common/components/base"
import { vBngBlur, vBngOnUiNav } from "@/common/directives"
import { lua } from "@/bridge"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { Accordion, AccordionItem } from "@/common/components/utility"

import { useUINavScope } from "@/services/uiNav"
useUINavScope("vehicleList")

const vehicleShoppingStore = useVehicleShoppingStore()
const dealerMetadata = ref({})
const inputFocused = ref(false)
const localSearchQuery = ref('')
const activeSearchQuery = ref('')
const sortOpen = ref(false)
const sortFieldLocal = ref('Value')
const sortDirectionLocal = ref('Ascending')
const selectedDealership = ref(null)

// Trigger search only on explicit action (Enter key or blur)
const triggerSearch = () => {
  activeSearchQuery.value = localSearchQuery.value.trim()
  inputFocused.value = false // Reset focus state
  vehicleShoppingStore.setSearchQuery(activeSearchQuery.value)
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
  let dealers = vehicleShoppingStore.vehiclesByDealer.slice();

  // Only filter out hidden dealers when we're viewing all dealers (not at a specific dealer)
  dealers = dealers.filter(dealer => {
    const dealerMeta = dealerMetadata.value[dealer.id]
    if (!dealerMeta) return true

    // Check organization's hiddenFromDealerList based on current reputation level
    let orgHidden = !!dealerMeta.hiddenFromDealerList
    if (dealerMeta.associatedOrganization) {
      console.log(dealerMeta.associatedOrganization)
      const orgData = vehicleShoppingStore.vehicleShoppingData?.organizations?.[dealerMeta.associatedOrganization]
      if (orgData && orgData.reputationLevels && orgData.reputation && orgData.reputation.level !== undefined && orgData.reputation.level !== null) {
        const currentLevel = orgData.reputation.level + 2
        const levelData = orgData.reputationLevels[currentLevel]
        orgHidden = !!(levelData && levelData.hiddenFromDealerList)
        console.log("Hidden from dealer list:")
        console.log(orgHidden)
      }
    }

    // Show dealer if neither the dealer nor the organization level wants it hidden
    return !orgHidden;
  });

  return dealers.sort((a, b) => {
    const nameA = dealerMetadata.value[a.id]?.name || a.name;
    const nameB = dealerMetadata.value[b.id]?.name || b.name;
    return nameA.localeCompare(nameB);
  });
});

// Filter handling functions
const handleAddFilter = (filter) => {
  if (filter.type === 'range') {
    vehicleShoppingStore.setFilterRange(filter.category, filter.value[0], filter.value[1])
  } else if (filter.type === 'select') {
    vehicleShoppingStore.toggleFilterValue(filter.category, filter.value)
  }
}

function removeFilter(key) {
  vehicleShoppingStore.setFilterRange(key)
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
}

// Header Section
.header-section {
  flex: 0 0 auto;
  background: linear-gradient(135deg, var(--bng-cool-gray-900) 0%, var(--bng-cool-gray-875) 100%);
  border-bottom: 1px solid var(--bng-cool-gray-700);
  position: sticky;
  top: 0;
  z-index: 100;
  backdrop-filter: blur(8px);

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
    padding: 1rem;
    background: var(--bng-cool-gray-900);
    border-radius: var(--bng-corners-2);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);

    .search-section {
      position: relative;
      flex: 1;
      background: transparent;
      border-radius: var(--bng-corners-1);
      border: none;
      transition: all 0.2s ease;

      &:focus-within {
        border-color: transparent;
        box-shadow: none;
      }

      .search-icon {
        position: absolute;
        left: 0.875rem;
        top: 50%;
        transform: translateY(-50%);
        color: var(--bng-orange);
        width: 1.125rem;
        height: 1.125rem;
        z-index: 2;
      }

      .search-input {
        width: 100%;
        padding: 0.75rem 1rem 0.75rem 2.75rem;
        height: 2.75rem;
        background: transparent;
        border: none;
        border-bottom: none !important;
        box-shadow: none !important;
        color: var(--bng-off-white);
        font-size: 0.875rem;
        border-radius: var(--bng-corners-1);

        &::placeholder {
          color: var(--bng-cool-gray-400);
          font-weight: 400;
        }

        &:focus {
          outline: none;
        }

        &:focus::placeholder {
          color: var(--bng-cool-gray-500);
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
  }
}

// Main Content
.main-content {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
  color: var(--bng-off-white);
  padding: 1rem;
  max-width: 80rem;
  margin: 0 auto;
  width: 100%;

  .price-notice {
    display: flex;
    justify-content: flex-end;
    padding: 0.25rem 0 1rem 0;
    color: var(--bng-cool-gray-300);
    font-size: 0.875rem;
  }

  .content-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;

    .content-title {
      font-size: 1.25rem;
      font-weight: 500;
      color: var(--bng-off-white);
      margin: 0;
    }

    .vehicle-count {
      font-size: 0.875rem;
      color: var(--bng-cool-gray-300);
      margin: 0;
    }
  }

  .content-subtitle {
    font-size: 0.875rem;
    color: var(--bng-cool-gray-300);
    margin-bottom: 1rem;
  }
}

// Dealership Section
.dealership-section {
  margin-bottom: 2rem;

  .section-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;

    .section-title {
      font-size: 1.125rem;
      font-weight: 500;
      color: var(--bng-off-white);
      margin: 0;
    }

    .show-all-btn {
      color: var(--bng-orange);
      border: 1px solid var(--bng-orange-alpha-50);

      &:hover {
        background: var(--bng-orange-alpha-20);
      }
    }
  }

  .dealership-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 1rem;
  }

  .dealership-card {
    display: grid;
    grid-template-columns: auto 1fr auto;
    grid-template-rows: auto auto 1fr;
    grid-template-areas:
      "icon name preview"
      "icon desc preview"
      "icon stats preview";
    column-gap: 1rem;
    row-gap: 0.25rem;
    padding: 1rem;
    background: var(--bng-cool-gray-900);
    border: 1px solid var(--bng-cool-gray-700);
    border-radius: var(--bng-corners-2);
    cursor: pointer;
    transition: all 0.3s ease;
    align-items: center;
    position: relative;

    &:hover {
      border-color: var(--bng-orange-alpha-50);
      transform: translateY(-1px);
      box-shadow: 0 2px 8px rgba(0,0,0,0.2);
    }

    &.selected {
      background: var(--bng-orange-alpha-5);
      border-color: var(--bng-orange);
      box-shadow: 0 0 0 1px var(--bng-orange-alpha-50);
    }

    .dealership-icon {
      grid-area: icon;
      width: 3.25rem;
      height: 3.25rem;
      border-radius: var(--bng-corners-1);
      display: flex;
      align-items: center;
      justify-content: center;
      background: var(--bng-cool-gray-800);
      color: var(--bng-orange);
      flex-shrink: 0;
    }

    &.selected .dealership-icon {
      background: var(--bng-orange);
      color: var(--bng-off-black);
    }

    .dealership-name {
      grid-area: name;
      align-self: center;
      font-weight: 500;
      margin: 0;
      color: var(--bng-off-white);
    }

    .dealership-description {
      grid-area: desc;
      font-size: 0.875rem;
      color: var(--bng-cool-gray-300);
      margin: 0;
    }

    .dealership-stats {
      grid-area: stats;
      display: flex;
      align-items: center;
      justify-content: space-between;

      .vehicle-count-badge {
        color: var(--bng-orange);
        font-weight: 600;
        font-size: 0.875rem;
      }

      .selected-badge {
        position: absolute;
        right: 0.75rem;
        bottom: 0.75rem;
        padding: 0.375rem 0.75rem;
        background: var(--bng-orange);
        color: var(--bng-off-black);
        border-radius: var(--bng-corners-1);
        font-size: 0.75rem;
        font-weight: 700;
        text-transform: uppercase;
        z-index: 2;
      }
    }

    .dealership-preview {
      grid-area: preview;
      width: 10rem;
      height: 6.5rem;
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
      border-radius: var(--bng-corners-1);
      flex-shrink: 0;
      border: 1px solid var(--bng-cool-gray-700);
    }
  }
}

// Vehicle Listings
.vehicle-listings {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
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
  padding: 4rem 2rem;
  text-align: center;
  background: var(--bng-cool-gray-900);
  border-radius: var(--bng-corners-2);
  border: 1px solid var(--bng-cool-gray-700);

  .empty-icon {
    width: 4rem;
    height: 4rem;
    color: var(--bng-cool-gray-500);
    margin-bottom: 1rem;
  }

  .empty-title {
    font-weight: 500;
    margin: 0 0 0.5rem 0;
    color: var(--bng-off-white);
  }

  .empty-description {
    font-size: 0.875rem;
    color: var(--bng-cool-gray-300);
    margin: 0;
    max-width: 400px;
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
