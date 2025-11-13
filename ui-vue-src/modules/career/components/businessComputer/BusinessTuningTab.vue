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
                    <label>{{ varData.title }}</label>
                    <div class="slider-wrapper">
                      <input 
                        type="range" 
                        v-model.number="varData.valDis"
                        :min="varData.minDis ?? 0"
                        :max="varData.maxDis ?? 100"
                        :step="getStepValue(varData)"
                        class="slider"
                        :style="getSliderStyle(varData)"
                        @input="onTuningChange(varData.name, varData.valDis)"
                        :disabled="isSliderDisabled(varData)"
                      />
                      <input 
                        type="number"
                        v-model.number="varData.displayValue"
                        :min="getDisplayMin(varData)"
                        :max="getDisplayMax(varData)"
                        :step="getDisplayStep(varData)"
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
                </div>
              </div>
            </transition>
          </div>
        </div>

        <div class="tuning-controls">
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
    </template>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import { useEvents } from "@/services/events"

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
    const displayVal = varData.unit === '%' || varData.unit === 'percent' 
      ? (varData.valDis ?? varData.minDis ?? 0) * 100 
      : (varData.valDis ?? varData.minDis ?? 0)
    
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
    // Multiply by 100 for percentage display
    return (value * 100).toFixed(2)
  }
  if (unit) {
    return `${value}${unit}`
  }
  return value.toString()
}

const getDisplayValue = (varData) => {
  const value = varData.valDis ?? (varData.minDis ?? 0)
  if (varData.unit === '%' || varData.unit === 'percent') {
    return value * 100
  }
  return value
}

const getDisplayMin = (varData) => {
  const min = varData.minDis ?? 0
  if (varData.unit === '%' || varData.unit === 'percent') {
    return min * 100
  }
  return min
}

const getDisplayMax = (varData) => {
  const max = varData.maxDis ?? 100
  if (varData.unit === '%' || varData.unit === 'percent') {
    return max * 100
  }
  return max
}

const getDisplayStep = (varData) => {
  const step = getStepValue(varData)
  if (varData.unit === '%' || varData.unit === 'percent') {
    return step * 100
  }
  return step
}

const onValueInput = (varData) => {
  let inputValue = varData.displayValue
  if (isNaN(inputValue) || inputValue === null || inputValue === undefined) {
    return
  }
  
  if (varData.unit === '%' || varData.unit === 'percent') {
    inputValue = inputValue / 100
  }
  
  const min = varData.minDis ?? 0
  const max = varData.maxDis ?? 100
  inputValue = Math.max(min, Math.min(max, inputValue))
  
  varData.valDis = inputValue
  
  if (tuningVariables.value[varData.name]) {
    tuningVariables.value[varData.name].valDis = inputValue
    if (varData.unit === '%' || varData.unit === 'percent') {
      tuningVariables.value[varData.name].displayValue = inputValue * 100
    } else {
      tuningVariables.value[varData.name].displayValue = inputValue
    }
  }
  
  onTuningChange(varData.name, inputValue)
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
  const min = varData.minDis ?? 0
  const max = varData.maxDis ?? 100
  const value = varData.valDis ?? min
  
  // Handle invalid values
  if (isNaN(min) || isNaN(max) || isNaN(value)) {
    return {
      '--slider-percentage': '0%'
    }
  }
  
  // Handle edge case where min equals max
  if (max === min) {
    return {
      '--slider-percentage': '0%'
    }
  }
  
  // Calculate percentage and clamp between 0 and 100
  let percentage = ((value - min) / (max - min)) * 100
  percentage = Math.max(0, Math.min(100, percentage))
  
  // Ensure we return a valid percentage string
  if (isNaN(percentage)) {
    percentage = 0
  }
  
  return {
    '--slider-percentage': `${percentage}%`
  }
}

const handleTuningData = (data) => {
  if (!data || !data.success) {
    console.error("Failed to load tuning data:", data?.error)
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
          baseline[varName].displayValue = currentVal * 100
        } else {
          baseline[varName].displayValue = currentVal
        }
      }
      
      originalTuningVariables.value = baseline
      buckets.value = organizeTuningData(data.tuningData)
    }
    loading.value = false
  }
}

const loadTuningData = async () => {
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) {
    loading.value = false
    return
  }
  
  // Always show loading state immediately
  loading.value = true
  
  // Request data (returns immediately, data comes via hook)
  // Lua will check cache and return instantly if cached
  store.requestVehicleTuningData(store.pulledOutVehicle.vehicleId).catch(error => {
    console.error("Failed to request tuning data:", error)
    loading.value = false
  })
}

const onTuningChange = (varName, value) => {
  if (!tuningVariables.value[varName]) return
  
  tuningVariables.value[varName].valDis = value
  
  const varData = tuningVariables.value[varName]
  if (varData.unit === '%' || varData.unit === 'percent') {
    varData.displayValue = value * 100
  } else {
    varData.displayValue = value
  }
  
  for (const bucket of buckets.value) {
    for (const subCategory of bucket.items) {
      for (const item of subCategory.items) {
        if (item.name === varName) {
          item.displayValue = varData.displayValue
          item.valDis = value
          break
        }
      }
    }
  }
  
  // Only add to cart and apply if live updates are enabled
  // Otherwise, user must press Apply button to add to cart
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
  if (!tuningVariables.value || !originalTuningVariables.value) return
  
  const cart = Array.isArray(store.tuningCart) ? store.tuningCart : []
  
  const cartTuningMap = {}
  cart.forEach(item => {
    cartTuningMap[item.varName] = item.value
  })
  
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (cartTuningMap.hasOwnProperty(varName)) {
      varData.valDis = cartTuningMap[varName]
    } else {
      const originalData = originalTuningVariables.value[varName]
      if (originalData) {
        const resetVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? originalData.val : (originalData.minDis !== undefined ? originalData.minDis : 0))
        varData.valDis = resetVal
      }
    }
    
    if (varData.unit === '%' || varData.unit === 'percent') {
      varData.displayValue = varData.valDis * 100
    } else {
      varData.displayValue = varData.valDis
    }
  }
  
  buckets.value = organizeTuningData(tuningVariables.value)
  
  store.updatePowerWeight()
}

const resetSettings = async () => {
  if (!originalTuningVariables.value || !store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return
  
  const baselineTuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    if (originalData) {
      const baselineVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? originalData.val : (originalData.minDis !== undefined ? originalData.minDis : 0))
      baselineTuningVars[varName] = baselineVal
    } else {
      const currentVal = varData.valDis !== undefined ? varData.valDis : (varData.val !== undefined ? varData.val : (varData.minDis !== undefined ? varData.minDis : 0))
      baselineTuningVars[varName] = currentVal
    }
  }
  
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    const originalData = originalTuningVariables.value[varName]
    let resetVal
    
    if (originalData) {
      resetVal = originalData.valDis !== undefined ? originalData.valDis : (originalData.val !== undefined ? originalData.val : (originalData.minDis !== undefined ? originalData.minDis : 0))
    } else {
      resetVal = varData.valDis !== undefined ? varData.valDis : (varData.val !== undefined ? varData.val : (varData.minDis !== undefined ? varData.minDis : 0))
    }
    
    tuningVariables.value[varName].valDis = resetVal
    
    if (tuningVariables.value[varName].unit === '%' || tuningVariables.value[varName].unit === 'percent') {
      tuningVariables.value[varName].displayValue = resetVal * 100
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
    console.error("Failed to apply baseline tuning:", error)
  }
  
  await store.addTuningToCart({}, originalTuningVariables.value)
  
  store.updatePowerWeight()
  
  if (liveUpdates.value) {
    applySettings()
  }
}

const applySettings = async () => {
  if (!store.pulledOutVehicle || !store.pulledOutVehicle.vehicleId) return
  
  const tuningVars = {}
  for (const [varName, varData] of Object.entries(tuningVariables.value)) {
    if (varData.valDis !== undefined) {
      tuningVars[varName] = varData.valDis
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
    console.error("Failed to apply tuning settings:", error)
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
  if (store.vehicleView === 'tuning') {
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
  
  label {
    display: block;
    color: rgba(255, 255, 255, 0.7);
    margin-bottom: 0.5rem;
    font-size: 0.875rem;
  }
  
  .slider-wrapper {
    display: flex;
    align-items: center;
    gap: 1rem;
    
    .slider {
      flex: 1;
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
    
    .value-input {
      min-width: 4rem;
      padding: 0.25rem 0.5rem;
      background: rgba(26, 26, 26, 1);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 0.25rem;
      text-align: center;
      color: white;
      font-size: 0.875rem;
      outline: none;
      
      /* Remove spinner arrows */
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
      margin-left: 0.25rem;
    }
    
    .value {
      min-width: 4rem;
      padding: 0.25rem 0.5rem;
      background: rgba(26, 26, 26, 1);
      border-radius: 0.25rem;
      text-align: center;
      color: white;
      font-size: 0.875rem;
    }
  }
}

.tuning-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1rem;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5rem;
  flex-shrink: 0;
  margin-top: 1rem;
  
  .switch-label {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    font-size: 0.875rem;
    position: relative;
    
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

