<template>
  <div class="filter-dropdown">
    <!-- Active filters preview -->
    <div v-if="activeFilters.length > 0" class="active-filters-preview">
      <div 
        v-for="filter in activeFilters.slice(0, 2)" 
        :key="filter.id" 
        class="filter-badge"
      >
        {{ filter.displayValue }}
        <button
          @click="removeFilter(filter.id)"
          class="remove-btn"
        >
          <BngIcon :type="icons.abandon" />
        </button>
      </div>
      <div v-if="activeFilters.length > 2" class="more-filters-badge">
        +{{ activeFilters.length - 2 }} more
      </div>
    </div>

    <!-- Filter dropdown -->
    <BngDropdownContainer v-model:opened="isOpen" class="filter-dropdown-container">
      <template #display>
        <div class="filter-btn" :class="{ active: isOpen }">
          <BngIcon :type="icons.filter" />
          Filters
          <div v-if="activeFilters.length > 0" class="filter-count">
            {{ activeFilters.length }}
          </div>
        </div>
      </template>

      <div class="filter-panel">
        <div class="filter-grid">
          <!-- Left Column - Active Filters -->
          <div class="active-filters-column">
            <div class="column-header">
              <div class="header-title">
                <BngIcon :type="icons.filter" />
                <span>Active Filters</span>
              </div>
              <BngButton 
                v-if="activeFilters.length > 0"
                :accent="ACCENTS.secondary"
                size="sm"
                @click="clearAllFilters"
                class="clear-all-btn"
              >
                Clear all
              </BngButton>
            </div>

            <div v-if="activeFilters.length > 0" class="filter-count-text">
              {{ activeFilters.length }} filter{{ activeFilters.length !== 1 ? 's' : '' }} active
            </div>

            <div class="active-filters-list" v-if="activeFilters.length > 0">
              <div 
                v-for="filter in activeFilters" 
                :key="filter.id" 
                class="active-filter-item"
              >
                <div class="filter-content">
                  <div class="filter-category">{{ filter.category }}</div>
                  <div class="filter-label">{{ filter.label }}</div>
                  <div class="filter-display">{{ filter.displayValue }}</div>
                </div>
                <BngButton
                  :accent="ACCENTS.secondary"
                  size="sm"
                  @click="removeFilter(filter.id)"
                  class="remove-filter-btn"
                >
                  <BngIcon :type="icons.abandon" />
                </BngButton>
              </div>
            </div>

            <div v-else class="no-filters-message">
              <BngIcon :type="icons.filter" class="empty-icon" />
              <h4>No active filters</h4>
              <p>Add filters from the options on the right</p>
            </div>
          </div>

          <!-- Right Column - Filter Creation -->
          <div class="filter-creation-column">
            <div class="column-header">
              <div class="header-title">
                <BngIcon :type="icons.adjust" />
                <span>Add Filters</span>
              </div>
            </div>
            <div class="creation-subtitle">
              Select from the categories below to add new filters
            </div>

            <div class="filter-tabs-container">
              <div class="filter-tabs">
                <BngButton 
                  :accent="ACCENTS.menu"
                  size="sm"
                  @click="activeTab = 'basic'"
                  :class="['tab-btn', { 'is-active': activeTab === 'basic' }]"
                >
                  Basic
                </BngButton>
                <BngButton 
                  :accent="ACCENTS.menu"
                  size="sm"
                  @click="activeTab = 'advanced'"
                  :class="['tab-btn', { 'is-active': activeTab === 'advanced' }]"
                >
                  Advanced
                </BngButton>
                <BngButton 
                  :accent="ACCENTS.menu"
                  size="sm"
                  @click="activeTab = 'custom'"
                  :class="['tab-btn', { 'is-active': activeTab === 'custom' }]"
                >
                  Custom
                </BngButton>
              </div>
            </div>

            <!-- Filter Creation Content -->
            <div class="filter-creation-content" v-show="isOpen">
              <!-- Basic Filters -->
              <div v-if="activeTab === 'basic'" class="filter-section">
                <!-- Hide Sold Filter - Simple toggle -->
                <div class="hide-sold-toggle">
                  <label class="toggle-option compact">
                    <input type="checkbox" v-model="hideSold" />
                    <span>Hide sold vehicles</span>
                  </label>
                </div>

                <!-- Make Filter -->
                <FilterSection :active="!!selectedMake">
                  <template #title>Make</template>
                  <BngSelect v-model="selectedMake" :options="makeOptions" />
                  <template #action>
                    <div class="action-container" :class="{ active: !!selectedMake }" @click="addMakeFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Make</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Price Range Filter -->
                <FilterSection :active="priceMin !== priceBounds.min || priceMax !== priceBounds.max">
                  <template #title>
                    <div class="price-filter-header">
                      <span class="filter-title">Price Range</span>
                      <div class="can-afford-toggle" :class="{ active: canAfford }">
                        <label>
                          <input type="checkbox" v-model="canAfford" />
                          <span class="toggle-switch"></span>
                          <span class="toggle-label">
                            <BngIcon :type="icons.money" class="money-icon" />
                            <span class="afford-text">Can Afford</span>
                            <span class="money-amount">${{ formatNumber(playerMoney) }}</span>
                          </span>
                        </label>
                      </div>
                    </div>
                  </template>
                  <div class="range-pill">
                    <span class="currency-symbol">$</span>
                    <input class="range-input" type="number" v-model.lazy.number="priceMin" step="1000" placeholder="Min" v-bng-text-input />
                    <span class="sep">–</span>
                    <span class="currency-symbol">$</span>
                    <input class="range-input" type="number" v-model.lazy.number="priceMax" step="1000" placeholder="Max" v-bng-text-input />
                  </div>
                  <div class="dual-slider vertical compact" v-if="priceBoundsReady">
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="priceMin" :min="priceBounds.min || 0" :max="priceMax" :step="1000" />
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="priceMax" :min="priceMin" :max="effectivePriceBounds.max" :step="1000" />
                  </div>
                  <template #action>
                    <div class="action-container" :class="{ active: priceMin !== priceBounds.min || priceMax !== priceBounds.max }" @click="addPriceFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Price</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Vehicle Type Filter -->
                <FilterSection :active="!!selectedCategory">
                  <template #title>Vehicle Type</template>
                  <BngSelect v-model="selectedCategory" :options="categoryOptions" />
                  <template #action>
                    <div class="action-container" :class="{ active: !!selectedCategory }" @click="addCategoryFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Type</span>
                    </div>
                  </template>
                </FilterSection>
              </div>

              <!-- Advanced Filters -->
              <div v-if="activeTab === 'advanced'" class="filter-section">
                <!-- Transmission Filter -->
                <FilterSection :active="!!selectedTransmission">
                  <template #title>Transmission</template>
                  <BngSelect v-model="selectedTransmission" :options="transmissionOptions" />
                  <template #action>
                    <div class="action-container" :class="{ active: !!selectedTransmission }" @click="addTransmissionFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Transmission</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Fuel Type Filter -->
                <FilterSection :active="!!selectedFuelType">
                  <template #title>Fuel Type</template>
                  <BngSelect v-model="selectedFuelType" :options="fuelTypeOptions" />
                  <template #action>
                    <div class="action-container" :class="{ active: !!selectedFuelType }" @click="addFuelTypeFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Fuel Type</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Drivetrain Filter -->
                <FilterSection :active="!!selectedDrivetrain">
                  <template #title>Drivetrain</template>
                  <BngSelect v-model="selectedDrivetrain" :options="drivetrainOptions" />
                  <template #action>
                    <div class="action-container" :class="{ active: !!selectedDrivetrain }" @click="addDrivetrainFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Drivetrain</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Year Range Filter -->
                <FilterSection :active="yearMin !== yearBounds.min || yearMax !== yearBounds.max">
                  <template #title>Year</template>
                  <div class="range-pill">
                    <input class="range-input" type="number" v-model.lazy.number="yearMin" step="1" placeholder="Min" v-bng-text-input />
                    <span class="sep">-</span>
                    <input class="range-input" type="number" v-model.lazy.number="yearMax" step="1" placeholder="Max" v-bng-text-input />
                  </div>
                  <div class="dual-slider vertical compact" v-if="yearBoundsReady">
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="yearMin" :min="yearBounds.min" :max="yearMax" :step="1" />
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="yearMax" :min="yearMin" :max="yearBounds.max" :step="1" />
                  </div>
                  <template #action>
                    <div class="action-container" :class="{ active: yearMin !== yearBounds.min || yearMax !== yearBounds.max }" @click="addYearFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Year Range</span>
                    </div>
                  </template>
                </FilterSection>
              </div>

              <!-- Custom Filters -->
              <div v-if="activeTab === 'custom'" class="filter-section">
                <!-- Mileage Range Filter -->
                <FilterSection :active="mileageMin !== mileageBounds.min || mileageMax !== mileageBounds.max">
                  <template #title>Mileage</template>
                  <div class="range-pill">
                    <input class="range-input" type="number" v-model.lazy.number="mileageMin" step="5000" placeholder="Min" v-bng-text-input />
                    <span class="sep">-</span>
                    <input class="range-input" type="number" v-model.lazy.number="mileageMax" step="5000" placeholder="Max" v-bng-text-input />
                  </div>
                  <div class="dual-slider vertical compact" v-if="mileageBoundsReady">
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="mileageMin" :min="mileageBounds.min" :max="mileageMax" :step="5000" />
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="mileageMax" :min="mileageMin" :max="mileageBounds.max" :step="5000" />
                  </div>
                  <template #action>
                    <div class="action-container" :class="{ active: mileageMin !== mileageBounds.min || mileageMax !== mileageBounds.max }" @click="addMileageFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Mileage Range</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Power Range Filter -->
                <FilterSection :active="powerMin !== powerBounds.min || powerMax !== powerBounds.max">
                  <template #title>Power</template>
                  <div class="range-pill">
                    <input class="range-input" type="number" v-model.lazy.number="powerMin" step="10" placeholder="Min" v-bng-text-input />
                    <span class="sep">-</span>
                    <input class="range-input" type="number" v-model.lazy.number="powerMax" step="10" placeholder="Max" v-bng-text-input />
                  </div>
                  <div class="dual-slider vertical compact" v-if="powerBoundsReady">
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="powerMin" :min="powerBounds.min" :max="powerMax" :step="10" />
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="powerMax" :min="powerMin" :max="powerBounds.max" :step="10" />
                  </div>
                  <template #action>
                    <div class="action-container" :class="{ active: powerMin !== powerBounds.min || powerMax !== powerBounds.max }" @click="addPowerFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Power Range</span>
                    </div>
                  </template>
                </FilterSection>

                <!-- Weight Range Filter -->
                <FilterSection :active="weightMin !== weightBounds.min || weightMax !== weightBounds.max">
                  <template #title>Weight</template>
                  <div class="range-pill">
                    <input class="range-input" type="number" v-model.lazy.number="weightMin" step="10" placeholder="Min" v-bng-text-input />
                    <span class="sep">-</span>
                    <input class="range-input" type="number" v-model.lazy.number="weightMax" step="10" placeholder="Max" v-bng-text-input />
                  </div>
                  <div class="dual-slider vertical compact" v-if="weightBoundsReady">
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="weightMin" :min="weightBounds.min" :max="weightMax" :step="10" />
                    <BngSlider class="stacked" :style="{ '--bng-slider-margin': '.35em' }" v-model="weightMax" :min="weightMin" :max="weightBounds.max" :step="10" />
                  </div>
                  <template #action>
                    <div class="action-container" :class="{ active: weightMin !== weightBounds.min || weightMax !== weightBounds.max }" @click="addWeightFilter">
                      <BngIcon :type="icons.plus" />
                      <span style="margin-left: .4rem;">Add Weight Range</span>
                    </div>
                  </template>
                </FilterSection>
              </div>
            </div>
          </div>
        </div>
      </div>
    </BngDropdownContainer>
  </div>
</template>

<script setup>
import { ref, computed, watch, onBeforeUnmount } from "vue"
import { BngDropdownContainer, BngIcon, BngButton, BngSelect, BngSlider, BngInput, ACCENTS, icons } from "@/common/components/base"
import { lua } from "@/bridge"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import FilterSection from "./FilterSection.vue"

// Props
const props = defineProps({
  filters: {
    type: Object,
    default: () => ({})
  }
})

// Emits
const emit = defineEmits(['update:filters', 'add-filter', 'remove-filter', 'clear-filters'])

// State
const isOpen = ref(false)
const activeTab = ref('basic')

// Vehicle data for dynamic bounds
const vehicleShoppingStore = useVehicleShoppingStore?.() || null
const allVehicles = computed(() => {
  try {
    return (vehicleShoppingStore?.vehiclesByDealer || []).flatMap(d => d.vehicles || [])
  } catch (e) {
    return []
  }
})

// Player money from store data
const playerMoney = computed(() => Number((vehicleShoppingStore?.vehicleShoppingData?.playerAttributes?.money && (vehicleShoppingStore.vehicleShoppingData.playerAttributes.money.value ?? vehicleShoppingStore.vehicleShoppingData.playerAttributes.money)) || 0))

const getBounds = (key, fallbackMin, fallbackMax) => computed(() => {
  const list = allVehicles.value
  if (!list || list.length === 0) return { min: fallbackMin, max: fallbackMax }
  let min = Infinity, max = -Infinity
  for (const v of list) {
    const val = Number(v?.[key])
    if (!Number.isFinite(val)) continue
    if (val < min) min = val
    if (val > max) max = val
  }
  if (!Number.isFinite(min)) min = fallbackMin
  if (!Number.isFinite(max)) max = fallbackMax
  return { min, max }
})

const rawPriceBounds = getBounds('Value', 0, 100000)
const priceBounds = computed(() => {
  const min = Number(rawPriceBounds.value.min)
  const max = Number(rawPriceBounds.value.max)
  const step = 1000
  // Ensure prices are always integers rounded to nearest thousand
  const roundedMin = Number.isFinite(min) ? Math.round(min / step) * step : 0
  const roundedMax = Number.isFinite(max) ? Math.round(max / step) * step : step
  return { min: roundedMin, max: roundedMax }
})
const priceBoundsReady = computed(() => Number.isFinite(Number(rawPriceBounds.value.min)) && Number.isFinite(Number(rawPriceBounds.value.max)))
const yearBounds = getBounds('year', 1980, 2024)
const rawMileageBounds = getBounds('Mileage', 0, 300000)
const mileageBounds = computed(() => {
  const minM = Number(rawMileageBounds.value.min)
  const maxM = Number(rawMileageBounds.value.max)
  const unit = 1609 // meters per mile
  const roundedMin = Number.isFinite(minM) ? Math.floor(minM / unit) : 0
  const roundedMax = Number.isFinite(maxM) ? Math.ceil(maxM / unit) : 0
  return { min: roundedMin, max: roundedMax }
})
const yearBoundsReady = computed(() => Number.isFinite(Number(yearBounds.value.min)) && Number.isFinite(Number(yearBounds.value.max)))
const mileageBoundsReady = computed(() => Number.isFinite(Number(rawMileageBounds.value.min)) && Number.isFinite(Number(rawMileageBounds.value.max)))
const powerBounds = getBounds('Power', 50, 1000)
const rawWeightBounds = getBounds('Weight', 0, 10000)
const weightBounds = computed(() => {
  const min = Number(rawWeightBounds.value.min)
  const max = Number(rawWeightBounds.value.max)
  const step = 10
  const roundedMin = Number.isFinite(min) ? Math.floor(min / step) * step : 0
  const roundedMax = Number.isFinite(max) ? Math.ceil(max / step) * step : step
  return { min: roundedMin, max: roundedMax }
})
const powerBoundsReady = computed(() => Number.isFinite(Number(powerBounds.value.min)) && Number.isFinite(Number(powerBounds.value.max)))
const weightBoundsReady = computed(() => Number.isFinite(Number(rawWeightBounds.value.min)) && Number.isFinite(Number(rawWeightBounds.value.max)))

// Filter states
const selectedMake = ref('')
const selectedCategory = ref('')
const selectedTransmission = ref('')
const selectedFuelType = ref('')
const selectedDrivetrain = ref('')
const priceRange = ref([priceBounds.value?.min ?? 0, priceBounds.value?.max ?? 0])
const canAfford = ref(false)

// Sync hideSold with active filters
const hideSold = computed({
  get: () => {
    const filter = props.filters?.hideSold
    if (!filter) return false
    return filter.value === true || 
           (filter.values && filter.values.length > 0 && (filter.values[0] === true || filter.values[0] === 'true'))
  },
  set: (val) => {
    if (val) {
      emit('add-filter', {
        category: 'hideSold',
        type: 'boolean',
        label: 'Hide Sold',
        value: true,
        displayValue: 'Hide Sold Vehicles'
      })
    } else {
      emit('remove-filter', 'hideSold')
    }
  }
})

const effectivePriceBounds = computed(() => {
  const baseMax = priceBounds.value.max
  if (!canAfford.value) return { min: priceBounds.value.min, max: baseMax }
  const cap = Math.max(priceBounds.value.min, Math.min(playerMoney.value, baseMax))
  return { min: priceBounds.value.min, max: cap }
})
const yearRange = ref([yearBounds.value?.min ?? 1980, yearBounds.value?.max ?? 2024])
const mileageRange = ref([mileageBounds.value?.min ?? 0, mileageBounds.value?.max ?? 0])
const powerRange = ref([powerBounds.value?.min ?? 0, powerBounds.value?.max ?? 0])
const weightRange = ref([weightBounds.value?.min ?? 0, weightBounds.value?.max ?? 0])

// Options
const makeOptions = [
  'Gavril', 'Hirochi', 'Belasco', 'Bruckell', 'Autobello', 'Ibishu', 'Soliad', 'Cherrier'
]

const categoryOptions = [
  'Sedan', 'SUV', 'Hatchback', 'Coupe', 'Convertible', 'Truck', 'Van', 'Sports Car'
]

const transmissionOptions = ['Manual', 'Automatic', 'CVT']
const fuelTypeOptions = ['Gasoline', 'Diesel', 'Electric', 'Hybrid']
const drivetrainOptions = ['FWD', 'RWD', 'AWD', '4WD']
// removed unit switcher to simplify UX

// Safe format for numbers displayed in labels
const formatNumber = (val) => {
  const n = typeof val === 'number' ? val : Number(val)
  if (Number.isFinite(n)) return n.toLocaleString(undefined, { maximumFractionDigits: 0 })
  return '0'
}

// Ensure sliders always provide an array [min, max]
const ensureRangeRef = (rangeRef, minVal, maxVal) => {
  watch(rangeRef, (val) => {
    if (Array.isArray(val)) {
      // normalize missing values
      let a = Number.isFinite(Number(val[0])) ? Number(val[0]) : minVal
      let b = Number.isFinite(Number(val[1])) ? Number(val[1]) : maxVal

      // For price ranges, ensure they're integers rounded to nearest thousand
      if (rangeRef === priceRange) {
        a = Math.round(a / 1000) * 1000
        b = Math.round(b / 1000) * 1000
      }

      if (a !== val[0] || b !== val[1]) {
        rangeRef.value = [a, b]
      }
    } else {
      const num = Number(val)
      // For price ranges, ensure they're integers
      const finalNum = rangeRef === priceRange ? Math.round(num / 1000) * 1000 : (Number.isFinite(num) ? num : maxVal)
      rangeRef.value = [minVal, finalNum]
    }
  }, { immediate: true })
}

ensureRangeRef(priceRange, priceBounds.value.min, priceBounds.value.max)
ensureRangeRef(yearRange, yearBounds.value.min, yearBounds.value.max)
ensureRangeRef(mileageRange, mileageBounds.value.min, mileageBounds.value.max)
ensureRangeRef(powerRange, powerBounds.value.min, powerBounds.value.max)
ensureRangeRef(weightRange, weightBounds.value.min, weightBounds.value.max)

// Keep ranges within dynamic bounds
watch(priceBounds, ({min, max}) => {
  const [a, b] = priceRange.value
  // Ensure values are integers and within bounds
  const constrainedMin = Math.max(Math.round((a ?? min) / 1000) * 1000, min)
  const constrainedMax = Math.min(Math.round((b ?? max) / 1000) * 1000, max)
  const next = [constrainedMin, constrainedMax]
  if (next[0] !== a || next[1] !== b) priceRange.value = next
}, { immediate: true })
watch(yearBounds, ({min, max}) => {
  const [a, b] = yearRange.value
  const next = [Math.max(a ?? min, min), Math.min(b ?? max, max)]
  if (next[0] !== a || next[1] !== b) yearRange.value = next
}, { immediate: true })
watch(mileageBounds, ({min, max}) => {
  const [a, b] = mileageRange.value
  const next = [Math.max(a ?? min, min), Math.min(b ?? max, max)]
  if (next[0] !== a || next[1] !== b) mileageRange.value = next
}, { immediate: true })
watch(powerBounds, ({min, max}) => {
  const [a, b] = powerRange.value
  const next = [Math.max(a ?? min, min), Math.min(b ?? max, max)]
  if (next[0] !== a || next[1] !== b) powerRange.value = next
}, { immediate: true })

// Mirror single refs for stacked sliders
const priceMin = ref(priceRange.value?.[0] ?? priceBounds.value.min)
const priceMax = ref(priceRange.value?.[1] ?? priceBounds.value.max)
const yearMin = ref(yearRange.value?.[0] ?? yearBounds.value.min)
const yearMax = ref(yearRange.value?.[1] ?? yearBounds.value.max)
const mileageMin = ref(mileageRange.value?.[0] ?? mileageBounds.value.min)
const mileageMax = ref(mileageRange.value?.[1] ?? mileageBounds.value.max)
const powerMin = ref(powerRange.value?.[0] ?? powerBounds.value.min)
const powerMax = ref(powerRange.value?.[1] ?? powerBounds.value.max)
const weightMin = ref(weightRange.value?.[0] ?? weightBounds.value.min)
const weightMax = ref(weightRange.value?.[1] ?? weightBounds.value.max)

watch([priceMin, priceMax], ([a, b]) => { priceRange.value = [a, b] })
watch(priceRange, ([a, b]) => { priceMin.value = a; priceMax.value = b })
watch([yearMin, yearMax], ([a, b]) => { yearRange.value = [a, b] })
watch(yearRange, ([a, b]) => { yearMin.value = a; yearMax.value = b })
watch([mileageMin, mileageMax], ([a, b]) => { mileageRange.value = [a, b] })
watch(mileageRange, ([a, b]) => { mileageMin.value = a; mileageMax.value = b })
watch([powerMin, powerMax], ([a, b]) => { powerRange.value = [a, b] })
watch(weightRange, ([a, b]) => { weightMin.value = a; weightMax.value = b })
watch([weightMin, weightMax], ([a, b]) => { weightRange.value = [a, b] })
watch(powerRange, ([a, b]) => { powerMin.value = a; powerMax.value = b })

// Auto-cap priceMax when canAfford is toggled or money changes
watch([canAfford, playerMoney, priceBounds], () => {
  if (!canAfford.value) return
  const cap = effectivePriceBounds.value.max
  if (priceMax.value > cap) priceMax.value = cap
}, { immediate: true })

// Capture keyboard when the dropdown is opened so inputs always receive typing
watch(isOpen, (open) => {
  if (lua && lua.setCEFTyping) lua.setCEFTyping(!!open)
})
onBeforeUnmount(() => {
  if (lua && lua.setCEFTyping) lua.setCEFTyping(false)
})

// Convert filters to active filter objects
const activeFilters = computed(() => {
  const filters = []
  const currentFilters = props.filters || {}
  
  Object.entries(currentFilters).forEach(([key, value]) => {
    if (value && (value.min !== undefined || value.max !== undefined || (value.values && value.values.length > 0) || value.value !== undefined)) {
      let displayValue = ''
      
      // Special handling for hideSold filter
      if (key === 'hideSold') {
        displayValue = 'Hide Sold'
      } else if (value.min !== undefined && value.max !== undefined) {
        displayValue = `${value.min} - ${value.max}`
      } else if (value.values && value.values.length > 0) {
        // Don't show "true" for boolean values
        if (value.values[0] === true || value.values[0] === 'true') {
          displayValue = formatFieldLabel(key)
        } else {
          displayValue = value.values.join(', ')
        }
      }
      
      filters.push({
        id: key,
        category: key,
        label: formatFieldLabel(key),
        displayValue: displayValue,
        value: value
      })
    }
  })
  
  return filters
})

// Helper functions
const formatFieldLabel = (key) => {
  return key
    .replace(/_/g, ' ')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/^./, s => s.toUpperCase())
}

// Filter actions
const removeFilter = (filterId) => {
  emit('remove-filter', filterId)
}

const clearAllFilters = () => {
  emit('clear-filters')
}

const addFilter = (category, type, label, value, displayValue) => {
  emit('add-filter', {
    category,
    type,
    label,
    value,
    displayValue
  })
}

// Specific filter additions
const addMakeFilter = () => {
  const val = selectedMake.value || makeOptions[0]
  if (!val) return
  addFilter('Brand', 'select', 'Make', val, val)
  selectedMake.value = ''
}

const addPriceFilter = () => {
  const [min, max] = Array.isArray(priceRange.value) ? priceRange.value : [0, Number(priceRange.value) || 0]
  addFilter('Value', 'range', 'Price Range', [min, max], `$${formatNumber(min)} - $${formatNumber(max)}`)
}

const addCategoryFilter = () => {
  const val = selectedCategory.value || categoryOptions[0]
  if (!val) return
  addFilter('Category', 'select', 'Vehicle Type', val, val)
  selectedCategory.value = ''
}

const addTransmissionFilter = () => {
  const val = selectedTransmission.value || transmissionOptions[0]
  if (!val) return
  addFilter('Transmission', 'select', 'Transmission', val, val)
  selectedTransmission.value = ''
}

const addFuelTypeFilter = () => {
  const val = selectedFuelType.value || fuelTypeOptions[0]
  if (!val) return
  addFilter('Fuel Type', 'select', 'Fuel Type', val, val)
  selectedFuelType.value = ''
}

const addDrivetrainFilter = () => {
  const val = selectedDrivetrain.value || drivetrainOptions[0]
  if (!val) return
  addFilter('Drivetrain', 'select', 'Drivetrain', val, val)
  selectedDrivetrain.value = ''
}

const addYearFilter = () => {
  const [min, max] = Array.isArray(yearRange.value) ? yearRange.value : [1980, Number(yearRange.value) || 1980]
  addFilter('year', 'range', 'Year Range', [min, max], `${min} - ${max}`)
}

const addMileageFilter = () => {
  const [min, max] = Array.isArray(mileageRange.value) ? mileageRange.value : [0, Number(mileageRange.value) || 0]
  addFilter('Mileage', 'range', 'Mileage Range', [min, max], `${formatNumber(min)} - ${formatNumber(max)} mi`)
}

const addPowerFilter = () => {
  const [min, max] = Array.isArray(powerRange.value) ? powerRange.value : [50, Number(powerRange.value) || 50]
  addFilter('Power', 'range', 'Power Range', [min, max], `${min} - ${max} hp`)
}

const addWeightFilter = () => {
  const [min, max] = Array.isArray(weightRange.value) ? weightRange.value : [weightBounds.value.min, weightBounds.value.max]
  addFilter('Weight', 'range', 'Weight Range', [min, max], `${formatNumber(min)}-${formatNumber(max)} lbs`)
}
</script>

<style scoped lang="scss">
.filter-dropdown {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

/* Remove the outer button-like shell from BngDropdownContainer */
.filter-dropdown :deep(.bng-dropdown),
.filter-dropdown :deep(.bng-dropdown__container),
.filter-dropdown :deep(.dropdown-container) {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
  padding: 0 !important;
  overflow: visible !important;
}

/* Hide the small caret opener so only our .filter-btn is visible */
.filter-dropdown :deep(.bng-dropdown-opener),
.filter-dropdown :deep(.bng-dropdown__opener),
.filter-dropdown :deep(.dropdown-opener) {
  display: none !important;
}

/* Ensure all dropdown wrappers never constrain content height */
.filter-dropdown :deep(.bng-dropdown-content),
.filter-dropdown :deep(.bng-dropdown__content),
.filter-dropdown :deep(.dropdown-content),
.filter-dropdown :deep(.bng-dropdown-panel),
.filter-dropdown :deep(.bng-dropdown__panel),
.filter-dropdown :deep(.dropdown-panel) {
  max-height: none !important;
  overflow: visible !important;
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}

/* Kill default popover chrome that sits behind our custom panel */
.filter-dropdown :deep(.bng-popover),
.filter-dropdown :deep(.bng-popover__content) {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
  padding: 0 !important;
  overflow: visible !important;
}
.filter-dropdown :deep(.bng-popover__backdrop) {
  background: transparent !important;
}

.active-filters-preview {
  display: flex;
  align-items: center;
  gap: 0.25rem;

  .filter-badge {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.375rem 0.75rem;
    background: var(--bng-orange);
    color: var(--bng-off-black);
    border-radius: var(--bng-corners-1);
    font-size: 0.875rem;
    font-weight: 500;
    border: none;

    .remove-btn {
      background: none;
      border: none;
      color: var(--bng-off-black);
      cursor: pointer;
      padding: 0.125rem;
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 50%;
      width: 1rem;
      height: 1rem;
      margin-left: 0.25rem;
      
      &:hover {
        background: rgba(0,0,0,0.1);
      }
    }
  }

  .more-filters-badge {
    padding: 0.375rem 0.75rem;
    background: var(--bng-cool-gray-800);
    color: var(--bng-orange);
    border: 1px solid var(--bng-orange-alpha-50);
    border-radius: var(--bng-corners-1);
    font-size: 0.875rem;
    font-weight: 500;
  }
}

.filter-btn {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--bng-cool-gray-800);
  border: 1px solid var(--bng-cool-gray-600);
  border-radius: var(--bng-corners-1);
  color: var(--bng-off-white);
  cursor: pointer;
  transition: all 0.2s ease;
  font-size: 0.875rem;
  font-weight: 500;
  height: 2.75rem;
  padding: 0.75rem 1rem;

  &:hover {
    background: var(--bng-orange-alpha-10);
    border-color: var(--bng-orange-alpha-50);
  }

  &.active {
    border-color: var(--bng-orange);
    background: var(--bng-orange-alpha-10);
  }

  .filter-count {
    padding: 0.125rem 0.375rem;
    background: var(--bng-orange);
    color: var(--bng-off-black);
    border-radius: var(--bng-corners-1);
    font-size: 0.75rem;
    font-weight: 600;
    min-width: 1.125rem;
    height: 1.125rem;
    display: flex;
    align-items: center;
    justify-content: center;
    line-height: 1;
  }


}

.filter-panel {
  width: 48rem;
  max-width: calc(100vw - 4rem);
  height: auto;
  max-height: none;
  background: var(--bng-cool-gray-900);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: var(--bng-corners-2);
  box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  overflow: visible;
  margin-left: -10rem;
}

.filter-label-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
}

.price-filter-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  gap: 1rem;
  
  .filter-title {
    font-weight: 500;
    color: var(--bng-off-white);
  }
}

.can-afford-toggle {
  display: inline-flex;
  align-items: center;
  padding: 0.25rem 0.5rem;
  background: var(--bng-cool-gray-850);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: 9999px;
  transition: all 0.3s ease;
  
  &:hover {
    background: var(--bng-cool-gray-800);
    border-color: var(--bng-cool-gray-600);
  }
  
  &.active {
    background: var(--bng-orange-alpha-15);
    border-color: var(--bng-orange);
    
    .toggle-switch {
      background: var(--bng-orange);
      
      &::after {
        transform: translateX(1rem);
        background: var(--bng-off-black);
      }
    }
    
    .money-amount {
      color: var(--bng-orange);
      font-weight: 600;
    }
  }
  
  label {
    display: flex;
    align-items: center;
    cursor: pointer;
    gap: 0.5rem;
    
    input[type="checkbox"] {
      position: absolute;
      opacity: 0;
      pointer-events: none;
    }
  }
  
  .toggle-switch {
    position: relative;
    width: 2rem;
    height: 1.125rem;
    background: var(--bng-cool-gray-700);
    border-radius: 9999px;
    transition: all 0.3s ease;
    
    &::after {
      content: '';
      position: absolute;
      top: 0.125rem;
      left: 0.125rem;
      width: 0.875rem;
      height: 0.875rem;
      background: var(--bng-off-white);
      border-radius: 50%;
      transition: transform 0.3s ease;
    }
  }
  
  .toggle-label {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    font-size: 0.8125rem;
    color: var(--bng-cool-gray-100);
    
    .money-icon {
      width: 0.875rem;
      height: 0.875rem;
      color: var(--bng-cool-gray-400);
    }
    
    .afford-text {
      font-weight: 500;
    }
    
    .money-amount {
      color: var(--bng-cool-gray-300);
      font-weight: 500;
      transition: all 0.3s ease;
    }
  }
}

.toggle-option {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.375rem 0.5rem;
  background: var(--bng-cool-gray-850);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: var(--bng-corners-1);
  cursor: pointer;
  transition: all 0.2s ease;
  
  &:hover {
    background: var(--bng-cool-gray-800);
    border-color: var(--bng-cool-gray-600);
  }
  
  &.compact {
    padding: 0.25rem 0.375rem;
    background: transparent;
    border: none;
    
    &:hover {
      background: var(--bng-cool-gray-850);
    }
  }
  
  input[type="checkbox"] {
    width: 1rem;
    height: 1rem;
    cursor: pointer;
  }
  
  span {
    color: var(--bng-off-white);
    font-size: 0.75rem;
  }
}

.hide-sold-toggle {
  margin-bottom: 0.625rem;
  padding-bottom: 0.625rem;
  border-bottom: 1px solid var(--bng-cool-gray-700);
}



.range-pill {
  display: inline-flex;
  align-items: center;
  gap: 0.125rem;
  background: var(--bng-cool-gray-850);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: 9999px;
  padding: 0.25rem 0.5rem;
  margin-bottom: 0.375rem;
  
  .currency-symbol {
    color: var(--bng-cool-gray-400);
    font-size: 0.75rem;
    font-weight: 500;
    margin-right: 0.0625rem;
  }
  
  .sep {
    color: var(--bng-cool-gray-500);
    font-weight: 500;
    margin: 0 0.125rem;
  }
  
  .range-input {
    width: 4.5rem;
    background: transparent;
    border: none;
    color: var(--bng-off-white);
    outline: none;
    font-size: 0.75rem;
    padding: 0;
    
    &::-webkit-outer-spin-button,
    &::-webkit-inner-spin-button {
      -webkit-appearance: none;
      margin: 0;
    }
    
    &:focus {
      color: var(--bng-orange);
    }
    
    &::placeholder {
      color: var(--bng-cool-gray-500);
    }
  }
}
.dual-slider.compact :deep(.bng-slider) {
  margin-top: 0.15rem;
  margin-bottom: 0.15rem;
}

.filter-grid {
  display: grid;
  grid-template-columns: 1fr 2fr;
  height: auto;
}

.active-filters-column {
  border-right: 1px solid var(--bng-cool-gray-700);
  background: var(--bng-cool-gray-875);
  display: flex;
  flex-direction: column;
}

.filter-creation-column {
  display: flex;
  flex-direction: column;
  background: var(--bng-cool-gray-900);
  max-height: 60vh;
  overflow: auto;
}

.column-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.625rem 0.75rem;
  border-bottom: 1px solid var(--bng-cool-gray-600);

  .header-title {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    font-weight: 500;
    font-size: 0.8125rem;
    color: var(--bng-off-white);
  }

  .clear-all-btn {
    color: rgb(239, 68, 68);
    font-size: 0.75rem;
    padding: 0.25rem 0.5rem;
    
    &:hover {
      background: rgba(239, 68, 68, 0.1);
    }
  }
}

.filter-count-text {
  padding: 0.375rem 0.75rem 0;
  font-size: 0.75rem;
  color: var(--bng-cool-gray-300);
}

.creation-subtitle {
  padding: 0 0.75rem 0.375rem 0.75rem;
  font-size: 0.75rem;
  color: var(--bng-cool-gray-300);
}

.active-filters-list {
  flex: 1;
  overflow: visible;
  padding: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.375rem;

  .active-filter-item {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding: 0.5rem;
    background: var(--bng-cool-gray-800);
    border: 1px solid var(--bng-cool-gray-700);
    border-radius: var(--bng-corners-1);
    transition: all 0.2s ease;

    &:hover {
      border-color: var(--bng-orange-alpha-50);
      background: var(--bng-orange-alpha-5);
    }

    .filter-content {
      flex: 1;
      min-width: 0;

      .filter-category {
        padding: 0.1rem 0.25rem;
        background: var(--bng-orange-alpha-20);
        color: var(--bng-orange);
        border: 1px solid var(--bng-orange-alpha-50);
        border-radius: var(--bng-corners-1);
        font-size: 0.625rem;
        font-weight: 500;
        display: inline-block;
        margin-bottom: 0.125rem;
      }

      .filter-label {
        font-weight: 500;
        font-size: 0.75rem;
        color: var(--bng-off-white);
        margin-bottom: 0.0625rem;
      }

      .filter-display {
        font-size: 0.625rem;
        color: var(--bng-cool-gray-300);
      }
    }

    .remove-filter-btn {
      margin-left: 0.375rem;
      padding: 0.125rem;
      min-width: auto;
      font-size: 0.75rem;
    }
  }
}

.no-filters-message {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 1.5rem 0.75rem;
  color: var(--bng-cool-gray-400);

  .empty-icon {
    width: 2rem;
    height: 2rem;
    margin-bottom: 0.5rem;
    opacity: 0.5;
  }

  h4 {
    font-weight: 500;
    font-size: 0.875rem;
    margin: 0 0 0.25rem 0;
    color: var(--bng-off-white);
  }

  p {
    margin: 0;
    font-size: 0.75rem;
  }
}

.filter-tabs-container {
  padding: 0 0.75rem;
  margin-bottom: 0.625rem;
  display: flex;
  justify-content: center;
}
.filter-tabs {
  display: inline-flex;
  gap: 0.125rem;
  background: var(--bng-cool-gray-800);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: 9999px;
  padding: 0.125rem;
}
.filter-tabs .tab-btn {
  font-size: 0.75rem;
  border-radius: 9999px;
  background: transparent;
  border: none;
  color: var(--bng-off-white);
  display: flex;
  align-items: center;
  justify-content: center;
  height: 1.75rem;
  padding: 0 0.75rem;
  min-width: 4.5rem;
}
.filter-tabs .tab-btn :deep(button) {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  height: 1.75rem;
  padding: 0 0.75rem;
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}
.filter-tabs .tab-btn.is-active {
  background: var(--bng-orange);
  color: var(--bng-off-black);
}
.filter-tabs .tab-btn:is(:hover):not(.is-active) {
  background: var(--bng-orange-alpha-10);
  border-color: transparent;
}

.filter-creation-content {
  flex: 1;
  overflow: visible;
  padding: 0 0.75rem 0.75rem 0.75rem;
}

.filter-section {
  display: flex;
  flex-direction: column;
  gap: 0.625rem;
  

}

.dual-slider {
  display: flex;
  flex-direction: column;
}
.dual-slider.vertical .stacked {
  position: relative;
}

.filter-group {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;

  .filter-label {
    font-size: 0.875rem;
    font-weight: 500;
    color: var(--bng-off-white);
  }

  .add-filter-btn {
    background: var(--bng-orange);
    color: var(--bng-off-black);
    font-weight: 600;
    border: none;
    transition: all 0.2s ease;

    &:hover {
      background: var(--bng-orange-dark);
      transform: translateY(-1px);
    }

    &:disabled {
      background: var(--bng-cool-gray-700);
      color: var(--bng-cool-gray-400);
      transform: none;
      opacity: 0.6;
    }
  }
}

.range-labels {
  display: flex;
  justify-content: space-between;
  font-size: 0.75rem;
  color: var(--bng-cool-gray-400);
}

.weight-inputs {
  display: grid;
  grid-template-columns: 1fr 1fr auto;
  gap: 0.5rem;

  .weight-input {
    font-size: 0.875rem;
  }

  .weight-unit {
    width: 5rem;
  }
}
</style>
