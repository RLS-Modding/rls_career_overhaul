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
            <div class="filter-creation-content">
              <!-- Basic Filters -->
              <div v-if="activeTab === 'basic'" class="filter-section">
                <!-- Make Filter -->
                <div class="filter-group">
                  <label class="filter-label">Make</label>
                  <BngSelect v-model="selectedMake" :options="makeOptions" placeholder="Select make" />
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addMakeFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Make
                  </BngButton>
                </div>

                <!-- Price Range Filter -->
                <div class="filter-group">
                  <label class="filter-label">
                    Price: ${{ formatNumber(priceRange?.[0]) }} - ${{ formatNumber(priceRange?.[1]) }}
                  </label>
                  <div class="dual-slider vertical">
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="priceMin"
                      :min="priceBounds.min || 0"
                      :max="priceMax"
                      :step="1000"
                    />
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="priceMax"
                      :min="priceMin"
                      :max="priceBounds.max || 0"
                      :step="1000"
                    />
                  </div>
                  <div class="range-labels">
                    <span>${{ formatNumber(priceBounds.min) }}</span>
                    <span>${{ formatNumber(priceBounds.max) }}+</span>
                  </div>
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addPriceFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Price
                  </BngButton>
                </div>

                <!-- Vehicle Type Filter -->
                <div class="filter-group">
                  <label class="filter-label">Vehicle Type</label>
                  <BngSelect v-model="selectedCategory" :options="categoryOptions" placeholder="Select vehicle type" />
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addCategoryFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Type
                  </BngButton>
                </div>
              </div>

              <!-- Advanced Filters -->
              <div v-if="activeTab === 'advanced'" class="filter-section">
                <!-- Transmission Filter -->
                <div class="filter-group">
                  <label class="filter-label">Transmission</label>
                  <BngSelect v-model="selectedTransmission" :options="transmissionOptions" placeholder="Select transmission" />
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addTransmissionFilter"
                    :disabled="!selectedTransmission"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Transmission
                  </BngButton>
                </div>

                <!-- Fuel Type Filter -->
                <div class="filter-group">
                  <label class="filter-label">Fuel Type</label>
                  <BngSelect v-model="selectedFuelType" :options="fuelTypeOptions" placeholder="Select fuel type" />
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addFuelTypeFilter"
                    :disabled="!selectedFuelType"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Fuel Type
                  </BngButton>
                </div>

                <!-- Drivetrain Filter -->
                <div class="filter-group">
                  <label class="filter-label">Drivetrain</label>
                  <BngSelect v-model="selectedDrivetrain" :options="drivetrainOptions" placeholder="Select drivetrain" />
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addDrivetrainFilter"
                    :disabled="!selectedDrivetrain"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Drivetrain
                  </BngButton>
                </div>

                <!-- Year Range Filter -->
                <div class="filter-group">
                  <label class="filter-label">Year: {{ yearRange[0] }} - {{ yearRange[1] }}</label>
                  <div class="dual-slider vertical">
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="yearMin"
                      :min="yearBounds.min"
                      :max="yearMax"
                      :step="1"
                    />
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="yearMax"
                      :min="yearMin"
                      :max="yearBounds.max"
                      :step="1"
                    />
                  </div>
                  <div class="range-labels">
                    <span>{{ yearBounds.min }}</span>
                    <span>{{ yearBounds.max }}</span>
                  </div>
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addYearFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Year Range
                  </BngButton>
                </div>
              </div>

              <!-- Custom Filters -->
              <div v-if="activeTab === 'custom'" class="filter-section">
                <!-- Mileage Range Filter -->
                <div class="filter-group">
                  <label class="filter-label">
                    Mileage: {{ formatNumber(mileageRange?.[0]) }} - {{ formatNumber(mileageRange?.[1]) }} mi
                  </label>
                  <div class="dual-slider vertical">
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="mileageMin"
                      :min="mileageBounds.min"
                      :max="mileageMax"
                      :step="5000"
                    />
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="mileageMax"
                      :min="mileageMin"
                      :max="mileageBounds.max"
                      :step="5000"
                    />
                  </div>
                  <div class="range-labels">
                    <span>{{ formatNumber(mileageBounds.min) }} mi</span>
                    <span>{{ formatNumber(mileageBounds.max) }}+ mi</span>
                  </div>
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addMileageFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Mileage Range
                  </BngButton>
                </div>

                <!-- Power Range Filter -->
                <div class="filter-group">
                  <label class="filter-label">Power: {{ powerRange[0] }} - {{ powerRange[1] }} hp</label>
                  <div class="dual-slider vertical">
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="powerMin"
                      :min="powerBounds.min"
                      :max="powerMax"
                      :step="10"
                    />
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="powerMax"
                      :min="powerMin"
                      :max="powerBounds.max"
                      :step="10"
                    />
                  </div>
                  <div class="range-labels">
                    <span>{{ powerBounds.min }} hp</span>
                    <span>{{ powerBounds.max }}+ hp</span>
                  </div>
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addPowerFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Power Range
                  </BngButton>
                </div>

                <!-- Weight Range Filter -->
                <div class="filter-group">
                  <label class="filter-label">
                    Weight: {{ formatNumber(weightRange?.[0]) }} - {{ formatNumber(weightRange?.[1]) }} lbs
                  </label>
                  <div class="dual-slider vertical">
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="weightMin"
                      :min="weightBounds.min"
                      :max="weightMax"
                      :step="10"
                    />
                    <BngSlider 
                      class="stacked"
                      :style="{ '--bng-slider-margin': '0.7em' }"
                      v-model="weightMax"
                      :min="weightMin"
                      :max="weightBounds.max"
                      :step="10"
                    />
                  </div>
                  <div class="range-labels">
                    <span>{{ formatNumber(weightBounds.min) }} lbs</span>
                    <span>{{ formatNumber(weightBounds.max) }}+ lbs</span>
                  </div>
                  <BngButton 
                    :accent="ACCENTS.primary"
                    size="sm"
                    @click="addWeightFilter"
                    class="add-filter-btn"
                  >
                    <BngIcon :type="icons.plus" />
                    Add Weight Range
                  </BngButton>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </BngDropdownContainer>
  </div>
</template>

<script setup>
import { ref, computed, watch } from "vue"
import { BngDropdownContainer, BngIcon, BngButton, BngSelect, BngSlider, BngInput, ACCENTS, icons } from "@/common/components/base"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"

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
  const roundedMin = Number.isFinite(min) ? Math.floor(min / step) * step : 0
  const roundedMax = Number.isFinite(max) ? Math.ceil(max / step) * step : step
  return { min: roundedMin, max: roundedMax }
})
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

// Filter states
const selectedMake = ref('')
const selectedCategory = ref('')
const selectedTransmission = ref('')
const selectedFuelType = ref('')
const selectedDrivetrain = ref('')
const priceRange = ref([priceBounds.value.min, priceBounds.value.max])
const yearRange = ref([yearBounds.value.min, yearBounds.value.max])
const mileageRange = ref([mileageBounds.value.min, mileageBounds.value.max])
const powerRange = ref([powerBounds.value.min, powerBounds.value.max])
const weightRange = ref([weightBounds.value.min, weightBounds.value.max])

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
      const a = Number.isFinite(Number(val[0])) ? Number(val[0]) : minVal
      const b = Number.isFinite(Number(val[1])) ? Number(val[1]) : maxVal
      if (a !== val[0] || b !== val[1]) {
        rangeRef.value = [a, b]
      }
    } else {
      const num = Number(val)
      rangeRef.value = [minVal, Number.isFinite(num) ? num : maxVal]
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
  priceRange.value = [Math.max(a, min), Math.min(b, max)]
}, { immediate: true })
watch(yearBounds, ({min, max}) => {
  const [a, b] = yearRange.value
  yearRange.value = [Math.max(a, min), Math.min(b, max)]
}, { immediate: true })
watch(mileageBounds, ({min, max}) => {
  const [a, b] = mileageRange.value
  mileageRange.value = [Math.max(a, min), Math.min(b, max)]
}, { immediate: true })
watch(powerBounds, ({min, max}) => {
  const [a, b] = powerRange.value
  powerRange.value = [Math.max(a, min), Math.min(b, max)]
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

// Convert filters to active filter objects
const activeFilters = computed(() => {
  const filters = []
  const currentFilters = props.filters || {}
  
  Object.entries(currentFilters).forEach(([key, value]) => {
    if (value && (value.min !== undefined || value.max !== undefined || (value.values && value.values.length > 0))) {
      let displayValue = ''
      
      if (value.min !== undefined && value.max !== undefined) {
        displayValue = `${value.min} - ${value.max}`
      } else if (value.values && value.values.length > 0) {
        displayValue = value.values.join(', ')
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
  width: 60rem;
  max-width: calc(100vw - 4rem);
  height: auto;
  max-height: none;
  background: var(--bng-cool-gray-900);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: var(--bng-corners-2);
  box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  overflow: visible;
  margin-left: -12.5rem;
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
}

.column-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1rem;
  border-bottom: 1px solid var(--bng-cool-gray-600);

  .header-title {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-weight: 500;
    color: var(--bng-off-white);
  }

  .clear-all-btn {
    color: rgb(239, 68, 68);
    
    &:hover {
      background: rgba(239, 68, 68, 0.1);
    }
  }
}

.filter-count-text {
  padding: 0.5rem 1rem 0;
  font-size: 0.875rem;
  color: var(--bng-cool-gray-300);
}

.creation-subtitle {
  padding: 0 1rem 0.5rem 1rem;
  font-size: 0.875rem;
  color: var(--bng-cool-gray-300);
}

.active-filters-list {
  flex: 1;
  overflow: visible;
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;

  .active-filter-item {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    padding: 0.75rem;
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
        padding: 0.125rem 0.375rem;
        background: var(--bng-orange-alpha-20);
        color: var(--bng-orange);
        border: 1px solid var(--bng-orange-alpha-50);
        border-radius: var(--bng-corners-1);
        font-size: 0.75rem;
        font-weight: 500;
        display: inline-block;
        margin-bottom: 0.25rem;
      }

      .filter-label {
        font-weight: 500;
        font-size: 0.875rem;
        color: var(--bng-off-white);
        margin-bottom: 0.125rem;
      }

      .filter-display {
        font-size: 0.75rem;
        color: var(--bng-cool-gray-300);
      }
    }

    .remove-filter-btn {
      margin-left: 0.5rem;
      padding: 0.25rem;
      min-width: auto;
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
  padding: 2rem 1rem;
  color: var(--bng-cool-gray-400);

  .empty-icon {
    width: 3rem;
    height: 3rem;
    margin-bottom: 1rem;
    opacity: 0.5;
  }

  h4 {
    font-weight: 500;
    margin: 0 0 0.5rem 0;
    color: var(--bng-off-white);
  }

  p {
    margin: 0;
    font-size: 0.875rem;
  }
}

.filter-tabs-container {
  padding: 0 1rem;
  margin-bottom: 1rem;
  display: flex;
  justify-content: center;
}
.filter-tabs {
  display: inline-flex;
  gap: 0.25rem;
  background: var(--bng-cool-gray-800);
  border: 1px solid var(--bng-cool-gray-700);
  border-radius: 9999px;
  padding: 0.25rem;
}
.filter-tabs .tab-btn {
  font-size: 0.875rem;
  border-radius: 9999px;
  background: transparent;
  border: none;
  color: var(--bng-off-white);
  display: flex;
  align-items: center;
  justify-content: center;
  height: 2.25rem;
  padding: 0 1rem;
  min-width: 6rem;
}
.filter-tabs .tab-btn :deep(button) {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  height: 2.25rem;
  padding: 0 1rem;
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
  padding: 0 1rem 1rem 1rem;
}

.filter-section {
  display: flex;
  flex-direction: column;
  gap: 1rem;
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
