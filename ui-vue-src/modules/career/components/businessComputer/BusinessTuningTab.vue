<template>
  <div class="tuning-tab">
    <div v-if="!store.pulledOutVehicle" class="no-vehicle">
      <p>No vehicle in garage. Pull out a vehicle from Active Jobs to access tuning options.</p>
    </div>
    
    <template v-else>
      <!-- Loading State -->
      <div v-if="loading" class="loading">
        <p>Loading tuning data...</p>
      </div>
      
      <!-- Content - Only show when not loading -->
      <div v-else class="tuning-content-wrapper">
        <div class="search-section">
          <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/>
            <path d="m21 21-4.35-4.35"/>
          </svg>
          <input
            v-model="searchQuery"
            type="text"
            placeholder="Search tuning options"
            class="search-input"
            @focus="onSearchFocus"
            @blur="onSearchBlur"
            @keydown.enter.stop="triggerSearch"
            @keydown.stop @keyup.stop @keypress.stop
            v-bng-text-input
            :disabled="loading"
          />
          <button
            v-if="searchQuery.length > 0"
            @click="clearSearch"
            class="clear-search-button"
            type="button"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="18" y1="6" x2="6" y2="18"/>
              <line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
        </div>
        
        <div class="tuning-scrollable">
          <div v-if="filteredBuckets.length === 0" class="no-tuning-data">
            <p v-if="activeSearchQuery">No tuning options found matching "{{ activeSearchQuery }}"</p>
            <p v-else>No tuning options available for this vehicle.</p>
          </div>
          
          <div v-for="category in filteredBuckets" :key="category.name" class="tuning-section">
            <button class="section-header" @click="toggleSection(category.name)">
              <h3>{{ category.name }}</h3>
              <svg 
                class="chevron-icon" 
                width="20" 
                height="20" 
                viewBox="0 0 24 24" 
                fill="none" 
                stroke="currentColor" 
                stroke-width="2"
                :class="{ rotated: !isSectionCollapsed(category.name) }"
              >
                <polyline points="6 9 12 15 18 9"/>
              </svg>
            </button>
            <transition name="section-collapse">
              <div v-if="!isSectionCollapsed(category.name)" class="section-content">
                <div v-for="subCategory in category.items" :key="subCategory.name" class="subcategory-group">
                  <h4 v-if="subCategory.name !== 'Other' && subCategory.name" class="subcategory-heading">
                    {{ subCategory.name }}
                  </h4>
                  <div class="slider-control" v-for="varData in subCategory.items" :key="varData.name">
                    <div class="slider-header">
                      <label>{{ varData.title }}</label>
                      <div class="value-input-group">
                        <input 
                          type="number"
                          v-model.number="varData.displayValue"
                          :min="getDisplayMin(varData)"
                          :max="getDisplayMax(varData)"
                          :step="varData.category === 'Wheel Alignment' && (varData.unit === '%' || varData.unit === 'percent') ? 1 : getDisplayStep(varData)"
                          class="value-input"
                          @input="onValueInput(varData)"
                          @focus="onValueFocus"
                          @blur="onValueBlur(varData)"
                          @keydown.stop @keyup.stop @keypress.stop
                          v-bng-text-input
                          :disabled="isSliderDisabled(varData)"
                        />
                        <span v-if="varData.unit" class="value-unit">{{ varData.unit === 'percent' ? '%' : varData.unit }}</span>
                      </div>
                    </div>
                    <div class="slider-wrapper">
                      <input 
                        type="range" 
                        v-model.number="varData.displayValue"
                        :min="getDisplayMin(varData)"
                        :max="getDisplayMax(varData)"
                        :step="getDisplayStep(varData)"
                        class="slider"
                        :style="getSliderStyle(varData)"
                        @input="onSliderChange(varData)"
                        :disabled="isSliderDisabled(varData)"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </transition>
          </div>
        </div>

        <div class="tuning-controls">
          <div class="wheel-data-section">
            <button class="wheel-data-header" @click="toggleWheelData">
              <span class="wheel-data-label">Live Wheel Data</span>
              <svg 
                class="chevron-icon" 
                width="14" 
                height="14" 
                viewBox="0 0 24 24" 
                fill="none" 
                stroke="currentColor" 
                stroke-width="2"
                :class="{ rotated: wheelDataExpanded }"
              >
                <polyline points="6 9 12 15 18 9"/>
              </svg>
            </button>
            <transition name="section-collapse">
              <div v-if="wheelDataExpanded" class="wheel-data-content">
                <BusinessWheelData ref="wheelDataRef" :business-id="store.businessId" :vehicle-id="store.pulledOutVehicle?.vehicleId" />
              </div>
            </transition>
          </div>
          <div class="controls-row">
            <label class="switch-label">
              <input type="checkbox" v-model="liveUpdates" class="switch-input" />
              <span class="switch-slider"></span>
              <span class="switch-text">Live updates</span>
            </label>
            <div class="control-buttons">
              <button class="btn btn-secondary" @click="resetSettings">Reset</button>
              <button class="btn btn-primary" @click="applySettings">Apply</button>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import { useEvents } from "@/services/events"
import BusinessWheelData from "./BusinessWheelData.vue"

const store = useBusinessComputerStore()
const events = useEvents()

const liveUpdates = ref(false)
const loading = ref(true)
const tuningVariables = ref({})
const originalTuningVariables = ref({})
const buckets = ref([])
const collapsedSections = ref({})
const searchQuery = ref("")
const activeSearchQuery = ref("")
const wheelDataExpanded = ref(false)
const wheelDataRef = ref(null)
const damageLockWarning = () => {
  const info = store.damageLockInfo || {}
  const damage = Math.round(info.damage || 0)
  const threshold = info.threshold || 1000
  const message = `Vehicle damage (${damage}) exceeds the ${threshold} limit. Abandon the job to continue.`
  try {
    lua.ui_message(message, 5, "Business Computer", "error")
  } catch (error) {
    console.warn("Failed to show damage lock warning", error)
  }
}
const isDamageLocked = computed(() => store.isDamageLocked)
const guardDamageLock = () => {
  if (isDamageLocked.value) {
    damageLockWarning()
    return true
  }
  return false
}

const toggleWheelData = () => {
  wheelDataExpanded.value = !wheelDataExpanded.value
  if (wheelDataExpanded.value && wheelDataRef.value && wheelDataRef.value.reloadExtension) {
    wheelDataRef.value.reloadExtension()
  }
}

const onSearchFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onSearchBlur = () => {
  try { triggerSearch() } catch (_) {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const triggerSearch = () => {
  activeSearchQuery.value = searchQuery.value.trim()
  if (activeSearchQuery.value.length > 0) {
    filteredBuckets.value.forEach(bucket => {
      collapsedSections.value[bucket.name] = false
    })
  }
}

const clearSearch = () => {
  searchQuery.value = ""
  activeSearchQuery.value = ""
  try { lua.setCEFTyping(false) } catch (_) {}
}

const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

const filteredBuckets = computed(() => {
  if (!hasActiveSearch.value) {
    return buckets.value
  }
  
  const query = activeSearchQuery.value.toLowerCase()
  const filtered = []
  
  buckets.value.forEach(bucket => {
    const matchingSubCategories = []
    
    bucket.items.forEach(subCategory => {
      const matchingItems = subCategory.items.filter(item => {
        const title = (item.title || item.name || '').toLowerCase()
        return title.includes(query)
      })
      
      if (matchingItems.length > 0) {
        matchingSubCategories.push({
          ...subCategory,
          items: matchingItems.sort((a, b) => {
            const titleA = (a.title || a.name || '').toLowerCase()
            const titleB = (b.title || b.name || '').toLowerCase()
            return titleA.localeCompare(titleB)
          })
        })
      }
    })
    
    if (matchingSubCategories.length > 0) {
      filtered.push({
        ...bucket,
        items: matchingSubCategories.sort((a, b) => a.name.localeCompare(b.name))
      })
    }
  })
  
  return filtered.sort((a, b) => a.name.localeCompare(b.name))
})

const toggleSection = (sectionName) => {
  collapsedSections.value[sectionName] = !collapsedSections.value[sectionName]
}

const isSectionCollapsed = (sectionName) => {
  return collapsedSections.value[sectionName] === true
}

// Organize tuning variables into buckets (categories) with subcategories
const organizeTuningData = (tuningData) => {
  if (!tuningData) return []
  
  const bucketsMap = {}
  
  // Iterate through all tuning variables
  for (const [varName, varData] of Object.entries(tuningData)) {
    if (!varData || typeof varData !== 'object') continue
    
    const category = varData.category || 'Other'
    const subCategory = varData.subCategory || 'Other'
    
    // Initialize category bucket if it doesn't exist
    if (!bucketsMap[category]) {
      bucketsMap[category] = {
        name: category,
        items: {}
      }
    }
    
    // Initialize subcategory if it doesn't exist
    if (!bucketsMap[category].items[subCategory]) {
      bucketsMap[category].items[subCategory] = {
        name: subCategory,
        items: []
      }
    }
    
    // Add variable to subcategory
    let displayVal
    if (varData.unit === '%' || varData.unit === 'percent') {
      const actualValue = varData.valDis ?? varData.val ?? (varData.default ?? varData.min ?? 0)
      if (varData.category === "Wheel Alignment") {
        displayVal = Math.round(actualValue)
      } else {
        const min = varData.min ?? 0
        const max = varData.max ?? 100
        const minDis = varData.minDis ?? min
        const maxDis = varData.maxDis ?? max
        
        if (minDis !== min || maxDis !== max) {
          const actualRange = max - min
          const displayRange = maxDis - minDis
          if (actualRange > 0 && displayRange > 0) {
            displayVal = ((actualValue - min) / actualRange) * displayRange + minDis
          } else {
            displayVal = actualValue
          }
        } else {
          displayVal = actualValue
        }
      }
    } else {
      displayVal = varData.valDis ?? varData.val ?? (varData.default ?? varData.minDis ?? 0)
    }
    
    bucketsMap[category].items[subCategory].items.push({
      ...varData,
      name: varName,
      displayValue: displayVal
    })
  }
  
  // Convert buckets map to array
  const bucketsArray = []
  for (const [categoryName, categoryData] of Object.entries(bucketsMap)) {
    const subCategories = []
    for (const [subCategoryName, subCategoryData] of Object.entries(categoryData.items)) {
      subCategories.push(subCategoryData)
    }
    bucketsArray.push({
      name: categoryName,
      items: subCategories
    })
  }
  
  // Sort buckets, subcategories, and items alphabetically
  bucketsArray.sort((a, b) => a.name.localeCompare(b.name))
  bucketsArray.forEach(bucket => {
    bucket.items.sort((a, b) => a.name.localeCompare(b.name))
    bucket.items.forEach(subCategory => {
      subCategory.items.sort((a, b) => {
        const titleA = (a.title || a.name || '').toLowerCase()
        const titleB = (b.title || b.name || '').toLowerCase()
        return titleA.localeCompare(titleB)
      })
    })
  })
  
  return bucketsArray
}

const formatValue = (value, unit) => {
  if (unit === '%' || unit === 'percent') {
    return value.toFixed(2)
  }
  if (unit) {
    return `${value}${unit}`
  }
  return value.toString()
}

const getDisplayValue = (varData) => {
  const actualValue = varData.valDis ?? varData.val ?? (varData.default ?? varData.min ?? 0)
  if (varData.unit === '%' || varData.unit === 'percent') {
    if (varData.category === "Wheel Alignment") {
      return Math.round(actualValue)
    }
    
    const min = varData.min ?? 0
    const max = varData.max ?? 100
    const minDis = varData.minDis ?? min
    const maxDis = varData.maxDis ?? max
    
    if (minDis !== min || maxDis !== max) {
      const actualRange = max - min
      const displayRange = maxDis - minDis
      if (actualRange > 0 && displayRange > 0) {
        return ((actualValue - min) / actualRange) * displayRange + minDis
      }
    }
    
    return actualValue
  }
  return actualValue
}

const getDisplayMin = (varData) => {
  return varData.minDis ?? varData.min ?? 0
}

const getDisplayMax = (varData) => {
  return varData.maxDis ?? varData.max ?? 100
}

const getDisplayStep = (varData) => {
  if (varData.unit === '%' || varData.unit === 'percent') {
    if (varData.category === "Wheel Alignment") {
      return 1
    }
    
    const min = varData.min ?? 0
    const max = varData.max ?? 100
    const minDis = varData.minDis ?? min
    const maxDis = varData.maxDis ?? max
    
    if (minDis !== min || maxDis !== max) {
      const step = varData.stepDis ?? getStepValue(varData)
      return step
    }
  }
  
  return varData.stepDis ?? getStepValue(varData)
}

const onValueInput = (varData) => {
  let displayValue = varData.displayValue
  if (isNaN(displayValue) || displayValue === null || displayValue === undefined) {
    return
  }
  
  const minDis = varData.minDis ?? varData.min ?? 0
  const maxDis = varData.maxDis ?? varData.max ?? 100
  
  displayValue = Math.max(minDis, Math.min(maxDis, displayValue))
  
  let actualValue = displayValue
  
  if (varData.unit === '%' || varData.unit === 'percent') {
    if (varData.category === "Wheel Alignment") {
      displayValue = Math.round(displayValue)
      actualValue = displayValue
    } else {
      const min = varData.min ?? 0
      const max = varData.max ?? 100
      const actualRange = max - min
      const displayRange = maxDis - minDis
      
      if (minDis !== min || maxDis !== max) {
        if (actualRange > 0 && displayRange > 0) {
          actualValue = ((displayValue - minDis) / displayRange) * actualRange + min
        }
      }
    }
  }
  
  if (varData.category === "Wheel Alignment" && (varData.unit === '%' || varData.unit === 'percent')) {
    actualValue = Math.round(actualValue * 100) / 100
  }
  
  varData.valDis = actualValue
  varData.displayValue = displayValue
  
  if (tuningVariables.value[varData.name]) {
    tuningVariables.value[varData.name].valDis = actualValue
    tuningVariables.value[varData.name].displayValue = displayValue
  }
  
  onTuningChange(varData.name, actualValue)
}

const onValueFocus = () => {
  lua.setCEFTyping(true)
}

const onValueBlur = (varData) => {
  lua.setCEFTyping(false)
  // Ensure display value is synced with actual value
  varData.displayValue = getDisplayValue(varData)
}

const getStepValue = (varData) => {
  // If stepDis is provided and valid, use it
  if (varData.stepDis !== undefined && varData.stepDis !== null && !isNaN(varData.stepDis) && varData.stepDis > 0) {
    return varData.stepDis
  }
  
  // If step is provided and valid, use it
  if (varData.step !== undefined && varData.step !== null && !isNaN(varData.step) && varData.step > 0) {
    return varData.step
  }
  
  // Calculate a reasonable step based on the range
  const min = varData.minDis ?? 0
  const max = varData.maxDis ?? 100
  const range = Math.abs(max - min)
  
  // Use 1/1000th of the range, but ensure it's at least 0.001 and not too small
  const calculatedStep = Math.max(0.001, Math.min(1, range / 1000))
  
  return calculatedStep
}

const isSliderDisabled = (varData) => {
  const min = varData.minDis ?? 0
  const max = varData.maxDis ?? 100
  
  // Disable if min equals max or values are invalid
  if (min === max || isNaN(min) || isNaN(max)) {
    return true
  }
  
  // Disable if step is invalid or zero
  const step = getStepValue(varData)
  if (isNaN(step) || step <= 0) {
    return true
  }
  
  return false
}

const getSliderStyle = (varData) => {
  const minDis = varData.minDis ?? varData.min ?? 0
  const maxDis = varData.maxDis ?? varData.max ?? 100
  const displayValue = varData.displayValue ?? minDis
  
  if (isNaN(minDis) || isNaN(maxDis) || isNaN(displayValue)) {
    return {
      '--slider-percentage': '0%'
    }
  }
  
  if (maxDis === minDis) {
    return {
      '--slider-percentage': '0%'
    }
  }
  
  let percentage = ((displayValue - minDis) / (maxDis - minDis)) * 100
  percentage = Math.max(0, Math.min(100, percentage))
  
  if (isNaN(percentage)) {
    percentage = 0
  }
  
  return {
    '--slider-percentage': `${percentage}%`
  }
}

const handleTuningData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }
  
  if (data.vehicleId === store.pulledOutVehicle?.vehicleId && data.businessId === store.businessId) {
    if (data.tuningData) {
      // Cache the data in the store
      const cacheKey = `${data.businessId}_${data.vehicleId}`
      if (store.tuningDataCache) {
        store.tuningDataCache[cacheKey] = data.tuningData
      }
      
      tuningVariables.value = data.tuningData
      
      const baseline = {}
      
      for (const [varName, varData] of Object.entries(data.tuningData)) {
        baseline[varName] = JSON.parse(JSON.stringify(varData))
        
        const currentVal = varData.valDis !== undefined ? varData.valDis : (varData.val !== undefined ? varData.val : (varData.minDis !== undefined ? varData.minDis : 0))
        baseline[varName].valDis = currentVal
        baseline[varName].val = currentVal
        
        if (baseline[varName].unit === '%' || baseline[varName].unit === 'percent') {
          if (baseline[varName].category === "Wheel Alignment") {
            baseline[varName].displayValue = Math.round(currentVal)
          } else {
            const min = baseline[varName].min ?? 0
            const max = baseline[varName].max ?? 100
            const minDis = baseline[varName].minDis ?? min
            const maxDis = baseline[varName].maxDis ?? max
            
            if (minDis !== min || maxDis !== max) {
              const actualRange = max - min
              const displayRange = maxDis - minDis
              if (actualRange > 0 && displayRange > 0) {
                baseline[varName].displayValue = ((currentVal - min) / actualRange) * displayRange + minDis
              } else {
                baseline[varName].displayValue = currentVal
              }
            } else {
              baseline[varName].displayValue = currentVal
            }
          }
        } else {
          baseline[varName].displayValue = currentVal
        }
      }
      
      originalTuningVariables.value = baseline
      buckets.value = organizeTuningData(data.tuningData)
      
      // Load cart values into UI after tuning data is set up
      loadTuningFromCart()
    }
    loading.value = false
  }
}

const loadTuningData = async () => {
  if (guardDamageLock()) {
    loading.value = false
    return
  }
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) {
    loading.value = false
    return
  }
  
  // Always show loading state immediately
  loading.value = true
  
  // Request data (returns immediately, data comes via hook)
  // Lua will check cache and return instantly if cached
  store.requestVehicleTuningData(store.pulledOutVehicle.vehicleId).catch(error => {
    loading.value = false
  })
}

const onSliderChange = (varData) => {
  if (!varData || !tuningVariables.value[varData.name]) return
  
  let displayValue = varData.displayValue
  const minDis = varData.minDis ?? varData.min ?? 0
  const maxDis = varData.maxDis ?? varData.max ?? 100
  
  displayValue = Math.max(minDis, Math.min(maxDis, displayValue))
  
  let actualValue = displayValue
  
  if (varData.unit === '%' || varData.unit === 'percent') {
    if (varData.category === "Wheel Alignment") {
      displayValue = Math.round(displayValue)
      actualValue = displayValue
    } else {
      const min = varData.min ?? 0
      const max = varData.max ?? 100
      const actualRange = max - min
      const displayRange = maxDis - minDis
      
      if (minDis !== min || maxDis !== max) {
        if (actualRange > 0 && displayRange > 0) {
          actualValue = ((displayValue - minDis) / displayRange) * actualRange + min
        }
      }
    }
  }
  
  varData.displayValue = displayValue
  varData.valDis = actualValue
  
  tuningVariables.value[varData.name].valDis = actualValue
  tuningVariables.value[varData.name].displayValue = displayValue
  
  for (const bucket of buckets.value) {
    for (const subCategory of bucket.items) {
      for (const item of subCategory.items) {
        if (item.name === varData.name) {
          item.displayValue = displayValue
          item.valDis = actualValue
          break
        }
      }
    }
  }
  
  if (liveUpdates.value) {
    applySettings()
  }
}

const onTuningChange = (varName, actualValue) => {
  if (guardDamageLock()) {
    return
  }
  if (!tuningVariables.value[varName]) return
  
  const varData = tuningVariables.value[varName]
  
  if (varData.category === "Wheel Alignment" && (varData.unit === '%' || varData.unit === 'percent')) {
    actualValue = Math.round(actualValue / 0.01) * 0.01
  }
  
  tuningVariables.value[varName].valDis = actualValue
  
  if (varData.unit === '%' || varData.unit === 'percent') {
    if (varData.category === "Wheel Alignment") {
      varData.displayValue = Math.round(actualValue)
    } else {
      const min = varData.min ?? 0
      const max = varData.max ?? 100
      const minDis = varData.minDis ?? min
      const maxDis = varData.maxDis ?? max
      
      if (minDis !== min || maxDis !== max) {
        const actualRange = max - min
        const displayRange = maxDis - minDis
        if (actualRange > 0 && displayRange > 0) {
          varData.displayValue = ((actualValue - min) / actualRange) * displayRange + minDis
        } else {
          varData.displayValue = actualValue
        }
      } else {
        varData.displayValue = actualValue
      }
    }
  } else {
    varData.displayValue = actualValue
  }
  
  for (const bucket of buckets.value) {
    for (const subCategory of bucket.items) {
      for (const item of subCategory.items) {
        if (item.name === varName) {
          item.displayValue = varData.displayValue
          item.valDis = actualValue
          break
        }
      }
    }
  }
  
  if (liveUpdates.value) {
    applySettings()
  }
}

const hasChanges = computed(() => {
  if (!tuningVariables.value || !originalTuningVariables.value) return false
  
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const original = originalTuningVariables.value[varName]
    if (!original) continue
    
    if (varData.valDis !== original.valDis) {
      return true
    }
  }
  
  return false
})

const loadTuningFromCart = () => {
  if (guardDamageLock()) {
    return
  }
  if (!tuningVariables.value || !originalTuningVariables.value) return
  
  const cart = Array.isArray(store.tuningCart) ? store.tuningCart : []
  
  const cartTuningMap = {}
  cart.forEach(item => {
    // Only process variables, skip categories and subcategories
    if (item.type === 'variable' && item.varName && item.value !== undefined) {
      cartTuningMap[item.varName] = item.value
    }
  })
  
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (cartTuningMap.hasOwnProperty(varName)) {
      const actualValue = cartTuningMap[varName]
      varData.val = actualValue
      varData.valDis = convertWheelAlignmentToSlider(varData, actualValue)
    } else {
      const originalData = originalTuningVariables.value[varName]
      if (originalData) {
        const resetVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? convertWheelAlignmentToSlider(varData, originalData.val) : (originalData.minDis !== undefined ? originalData.minDis : 0))
        varData.valDis = resetVal
        varData.val = convertWheelAlignmentToActual(varData, resetVal)
      }
    }
    
    if (varData.unit === '%' || varData.unit === 'percent') {
      if (varData.category === "Wheel Alignment") {
        varData.displayValue = Math.round(varData.valDis)
      } else {
        const min = varData.min ?? 0
        const max = varData.max ?? 100
        const minDis = varData.minDis ?? min
        const maxDis = varData.maxDis ?? max
        
        if (minDis !== min || maxDis !== max) {
          const actualRange = max - min
          const displayRange = maxDis - minDis
          if (actualRange > 0 && displayRange > 0) {
            varData.displayValue = ((varData.valDis - min) / actualRange) * displayRange + minDis
          } else {
            varData.displayValue = varData.valDis
          }
        } else {
          varData.displayValue = varData.valDis
        }
      }
    } else {
      varData.displayValue = varData.valDis
    }
  }
  
  buckets.value = organizeTuningData(tuningVariables.value)
  
  store.updatePowerWeight()
}

const resetSettings = async () => {
  if (guardDamageLock()) {
    return
  }
  if (!originalTuningVariables.value || !store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return
  
  const baselineTuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    let baselineVal
    if (originalData) {
      baselineVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? originalData.val : (originalData.minDis !== undefined ? originalData.minDis : 0))
    } else {
      baselineVal = varData.valDis !== undefined ? varData.valDis : (varData.val !== undefined ? varData.val : (varData.minDis !== undefined ? varData.minDis : 0))
    }
    baselineTuningVars[varName] = convertWheelAlignmentToActual(varData, baselineVal)
  }
  
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    let resetVal
    
    if (originalData) {
      resetVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? convertWheelAlignmentToSlider(varData, originalData.val) : (originalData.minDis !== undefined ? originalData.minDis : 0))
    } else {
      resetVal = varData.valDis !== undefined ? varData.valDis : (varData.val !== undefined ? convertWheelAlignmentToSlider(varData, varData.val) : (varData.minDis !== undefined ? varData.minDis : 0))
    }
    
    tuningVariables.value[varName].valDis = resetVal
    
    if (tuningVariables.value[varName].unit === '%' || tuningVariables.value[varName].unit === 'percent') {
      if (tuningVariables.value[varName].category === "Wheel Alignment") {
        tuningVariables.value[varName].displayValue = Math.round(resetVal)
      } else {
        const min = tuningVariables.value[varName].min ?? 0
        const max = tuningVariables.value[varName].max ?? 100
        const minDis = tuningVariables.value[varName].minDis ?? min
        const maxDis = tuningVariables.value[varName].maxDis ?? max
        
        if (minDis !== min || maxDis !== max) {
          const actualRange = max - min
          const displayRange = maxDis - minDis
          if (actualRange > 0 && displayRange > 0) {
            tuningVariables.value[varName].displayValue = ((resetVal - min) / actualRange) * displayRange + minDis
          } else {
            tuningVariables.value[varName].displayValue = resetVal
          }
        } else {
          tuningVariables.value[varName].displayValue = resetVal
        }
      }
    } else {
      tuningVariables.value[varName].displayValue = resetVal
    }
  }
  
  buckets.value = organizeTuningData(tuningVariables.value)
  
  try {
    if (store.businessId) {
      await lua.career_modules_business_businessComputer.applyTuningToVehicle(
        store.businessId,
        store.pulledOutVehicle.vehicleId,
        baselineTuningVars
      )
      
      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    }
  } catch (error) {
  }
  
  await store.addTuningToCart({}, originalTuningVariables.value)
  
  store.updatePowerWeight()
  
  if (liveUpdates.value) {
    applySettings()
  }
}

const convertWheelAlignmentToActual = (varData, valDis) => {
  if (varData.category === "Wheel Alignment" && (varData.unit === '%' || varData.unit === 'percent')) {
    const actualMin = varData.min ?? 0
    const actualMax = varData.max ?? 100
    const range = actualMax - actualMin
    if (range > 0) {
      return ((valDis + 1) / 2) * range + actualMin
    }
    return actualMin
  }
  
  // Handle variables with display ranges (options.minDis/maxDis)
  if (varData.options && typeof varData.options === 'object') {
    const optionsMinDis = varData.options.minDis
    const optionsMaxDis = varData.options.maxDis
    if (optionsMinDis !== undefined || optionsMaxDis !== undefined) {
      const actualMin = varData.min ?? 0
      const actualMax = varData.max ?? 100
      const actualRange = actualMax - actualMin
      const displayMin = optionsMinDis ?? actualMin
      const displayMax = optionsMaxDis ?? actualMax
      const displayRange = displayMax - displayMin
      
      if (actualRange > 0 && displayRange > 0) {
        // Map from [displayMin, displayMax] back to [actualMin, actualMax]
        return ((valDis - displayMin) / displayRange) * actualRange + actualMin
      }
      return actualMin
    }
  }
  
  return valDis
}

const convertWheelAlignmentToSlider = (varData, actualValue) => {
  if (varData.category === "Wheel Alignment" && (varData.unit === '%' || varData.unit === 'percent')) {
    const actualMin = varData.min ?? 0
    const actualMax = varData.max ?? 100
    const range = actualMax - actualMin
    if (range > 0) {
      return ((actualValue - actualMin) / range) * 2 - 1
    }
    return 0
  }
  
  // Handle variables with display ranges (options.minDis/maxDis)
  if (varData.options && typeof varData.options === 'object') {
    const optionsMinDis = varData.options.minDis
    const optionsMaxDis = varData.options.maxDis
    if (optionsMinDis !== undefined || optionsMaxDis !== undefined) {
      const actualMin = varData.min ?? 0
      const actualMax = varData.max ?? 100
      const actualRange = actualMax - actualMin
      const displayMin = optionsMinDis ?? actualMin
      const displayMax = optionsMaxDis ?? actualMax
      const displayRange = displayMax - displayMin
      
      if (actualRange > 0 && displayRange > 0) {
        // Map from [actualMin, actualMax] to [displayMin, displayMax]
        return ((actualValue - actualMin) / actualRange) * displayRange + displayMin
      }
      return displayMin
    }
  }
  
  return actualValue
}

const applySettings = async () => {
  if (guardDamageLock()) {
    return
  }
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return
  
  const tuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (varData.valDis !== undefined) {
      tuningVars[varName] = convertWheelAlignmentToActual(varData, varData.valDis)
    }
  }
  
  try {
    await store.addTuningToCart(tuningVars, originalTuningVariables.value)
    
    if (store.businessId) {
      await lua.career_modules_business_businessComputer.applyTuningToVehicle(
        store.businessId,
        store.pulledOutVehicle.vehicleId,
        tuningVars
      )
      
      setTimeout(() => {
        if (store.vehicleView === 'parts') {
          store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId)
        }
      }, 100)
    }
    
    store.updatePowerWeight()
  } catch (error) {
  }
}

watch(() => store.pulledOutVehicle, (newVehicle, oldVehicle) => {
  if (!newVehicle) {
    tuningVariables.value = {}
    originalTuningVariables.value = {}
    buckets.value = []
    loading.value = false
    store.clearCart()
  }
})

onMounted(() => {
  events.on('businessComputer:onVehicleTuningData', handleTuningData)
  
  requestAnimationFrame(() => {
    setTimeout(() => {
      if (store.pulledOutVehicle) {
        loadTuningData()
      }
    }, 350)
  })
})

onBeforeUnmount(() => {
  events.off('businessComputer:onVehicleTuningData', handleTuningData)
})

watch(() => store.activeTabId, () => {
  if (store.vehicleView === 'tuning' && !store.isCurrentTabApplied) {
    loadTuningFromCart()
  }
})

defineExpose({
  resetSettings,
  loadTuningFromCart
})
</script>

<style scoped lang="scss">
.tuning-tab {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  height: 100%;
  overflow-y: auto;
}

.no-vehicle,
.loading,
.no-tuning-data {
  padding: 3rem;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.tuning-content-wrapper {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  gap: 1rem;
}

.search-section {
  position: relative;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  
  .search-icon {
    position: absolute;
    left: 0.75em;
    top: 50%;
    transform: translateY(-50%);
    color: rgba(255, 255, 255, 0.4);
    width: 1em;
    height: 1em;
    pointer-events: none;
    z-index: 1;
  }
  
  .search-input {
    width: 100%;
    padding: 0.75em 1em 0.75em 2.5em;
    background: rgba(23, 23, 23, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25em;
    color: white;
    font-size: 0.875em;
    
    &::placeholder {
      color: rgba(255, 255, 255, 0.5);
    }
    
    &:focus {
      outline: none;
      border-color: rgba(245, 73, 0, 0.5);
      padding-right: 2.5em;
    }
  }
  
  .clear-search-button {
    position: absolute;
    right: 0.5em;
    top: 50%;
    transform: translateY(-50%);
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(255, 255, 255, 0.5);
    transition: color 0.2s;
    z-index: 1;
    
    &:hover {
      color: rgba(255, 255, 255, 0.8);
    }
    
    svg {
      width: 1em;
      height: 1em;
    }
  }
}

.tuning-scrollable {
  flex: 1;
  overflow-y: auto;
  padding-bottom: 1rem;
  
  /* Custom scrollbar matching business computer */
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
}

.tuning-section {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  overflow: hidden;
  margin-bottom: 1.5rem;
  
  &:last-child {
    margin-bottom: 0;
  }
}

.section-header {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1rem 1.5rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
  border: none;
  cursor: pointer;
  transition: background 0.2s;
  
  &:hover {
    background: rgba(23, 23, 23, 0.5);
  }
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125rem;
    font-weight: 600;
  }
  
  .chevron-icon {
    color: rgba(255, 255, 255, 0.4);
    flex-shrink: 0;
    transition: transform 0.3s ease;
    
    &.rotated {
      transform: rotate(180deg);
    }
  }
}

.section-content {
  padding: 1.5rem;
  overflow: hidden;
}

.section-collapse-enter-active,
.section-collapse-leave-active {
  transition: max-height 0.3s ease, opacity 0.3s ease;
  overflow: hidden;
}

.section-collapse-enter-from {
  max-height: 0;
  opacity: 0;
}

.section-collapse-enter-to {
  max-height: 2000px;
  opacity: 1;
}

.section-collapse-leave-from {
  max-height: 2000px;
  opacity: 1;
}

.section-collapse-leave-to {
  max-height: 0;
  opacity: 0;
}

.subcategory-group {
  margin-bottom: 1.5rem;
  
  &:last-child {
    margin-bottom: 0;
  }
}

.subcategory-heading {
  margin: 0 0 1rem 0;
  color: rgba(255, 255, 255, 0.6);
  font-style: italic;
  font-size: 0.875rem;
  font-weight: 500;
}

.slider-control {
  margin-bottom: 1rem;
  
  &:last-child {
    margin-bottom: 0;
  }
  
  .slider-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 0.5rem;
    
    label {
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.875rem;
      margin: 0;
    }
    
    .value-input-group {
      display: flex;
      align-items: center;
      gap: 0.25rem;
    }
  }
  
  .slider-wrapper {
    width: 100%;
    
    .slider {
      width: 100%;
      height: 0.5rem;
      border-radius: 0.25rem;
      outline: none;
      border: none;
      -webkit-appearance: none;
      appearance: none;
      background: transparent;
      
      &::-webkit-slider-runnable-track {
        width: 100%;
        height: 0.5rem;
        border-radius: 0.25rem;
        border: none;
        background: linear-gradient(to right, rgba(245, 73, 0, 1) 0%, rgba(245, 73, 0, 1) var(--slider-percentage, 0%), rgba(255, 255, 255, 0.1) var(--slider-percentage, 0%), rgba(255, 255, 255, 0.1) 100%);
      }
      
      &::-moz-range-track {
        width: 100%;
        height: 0.5rem;
        border-radius: 0.25rem;
        border: none;
        background: linear-gradient(to right, rgba(245, 73, 0, 1) 0%, rgba(245, 73, 0, 1) var(--slider-percentage, 0%), rgba(255, 255, 255, 0.1) var(--slider-percentage, 0%), rgba(255, 255, 255, 0.1) 100%);
      }
      
      &::-webkit-slider-thumb {
        -webkit-appearance: none;
        appearance: none;
        width: 1rem;
        height: 1rem;
        background: rgba(245, 73, 0, 1);
        border-radius: 50%;
        cursor: pointer;
        margin-top: -0.25rem;
        border: none;
        box-shadow: none;
      }
      
      &::-moz-range-thumb {
        width: 1rem;
        height: 1rem;
        background: rgba(245, 73, 0, 1);
        border-radius: 50%;
        cursor: pointer;
        border: none;
        box-shadow: none;
      }
      
      &:disabled {
        opacity: 0.5;
        cursor: not-allowed;
        
        &::-webkit-slider-thumb {
          cursor: not-allowed;
        }
        
        &::-moz-range-thumb {
          cursor: not-allowed;
        }
      }
    }
  }
  
  .value-input {
    width: 5rem;
    padding: 0.25rem 0.5rem;
    background: rgba(26, 26, 26, 1);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25rem;
    text-align: center;
    color: white;
    font-size: 0.875rem;
    outline: none;
    
    appearance: textfield;
    -moz-appearance: textfield;
    
    &::-webkit-outer-spin-button,
    &::-webkit-inner-spin-button {
      -webkit-appearance: none;
      margin: 0;
    }
    
    &:focus {
      border-color: rgba(245, 73, 0, 0.5);
    }
    
    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }
  
  .value-unit {
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.875rem;
  }
}

.tuning-controls {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 1rem;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  flex-shrink: 0;
  margin-top: 1rem;
  
  .wheel-data-section {
    width: 100%;
    
    .wheel-data-header {
      width: 100%;
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.375rem 0.625rem;
      background: transparent;
      border: none;
      cursor: pointer;
      transition: background 0.2s;
      border-radius: 0.25rem;
      
      &:hover {
        background: rgba(255, 255, 255, 0.05);
      }
      
      .wheel-data-label {
        color: rgba(255, 255, 255, 0.6);
        font-size: 0.8125rem;
        user-select: none;
        font-weight: 500;
      }
      
      .chevron-icon {
        color: rgba(255, 255, 255, 0.4);
        flex-shrink: 0;
        transition: transform 0.3s ease;
        
        &.rotated {
          transform: rotate(180deg);
        }
      }
    }
    
    .wheel-data-content {
      margin-top: 0.25rem;
    }
  }
  
  .controls-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    gap: 1rem;
  }
  
  .switch-label {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    font-size: 0.875rem;
    position: relative;
    flex-shrink: 0;
    
    .switch-input {
      position: absolute;
      opacity: 0;
      width: 0;
      height: 0;
      
      &:checked + .switch-slider {
        background: rgba(245, 73, 0, 1);
        
        &::before {
          transform: translateX(1.5rem) translateY(-50%);
        }
      }
      
      &:focus + .switch-slider {
        box-shadow: 0 0 0 2px rgba(245, 73, 0, 0.3);
      }
    }
    
    .switch-slider {
      position: relative;
      display: inline-block;
      width: 3rem;
      height: 1.5rem;
      background: rgba(255, 255, 255, 0.1);
      border-radius: 0.75rem;
      transition: background 0.2s;
      flex-shrink: 0;
      
      &::before {
        content: '';
        position: absolute;
        width: 1.25rem;
        height: 1.25rem;
        left: 0.125rem;
        top: 50%;
        transform: translateY(-50%);
        background: white;
        border-radius: 50%;
        transition: transform 0.2s;
      }
    }
    
    .switch-text {
      user-select: none;
    }
  }
  
  .control-buttons {
    display: flex;
    gap: 0.5rem;
    flex-shrink: 0;
  }
}

.btn {
  padding: 0.5rem 1rem;
  border-radius: 0.375rem;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  
  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;
    
    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 0.9);
    }
    
    &:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
  }
  
  &.btn-secondary {
    background: rgba(55, 55, 55, 1);
    color: white;
    
    &:hover {
      background: rgba(75, 75, 75, 1);
    }
  }
}
</style>

