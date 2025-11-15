<template>
  <div class="parts-customization">
    <!-- Search Bar - Always visible -->
    <div class="search-section">
      <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="11" cy="11" r="8"/>
        <path d="m21 21-4.35-4.35"/>
      </svg>
      <input
        v-model="searchQuery"
        type="text"
        placeholder="Search for parts"
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

    <!-- Loading State -->
    <div v-if="loading" class="loading-state">
      <p>Loading parts...</p>
    </div>

    <!-- Content - Only show when not loading -->
    <template v-else>
      <!-- Breadcrumb Navigation (hidden when searching) -->
      <div v-if="navigationPath.length > 0 && !hasActiveSearch" class="breadcrumb-nav">
      <button
        @click="navigateToPath(-1)"
        class="breadcrumb-link"
      >
        All Parts
      </button>
      <template v-if="showEllipsis">
        <svg class="breadcrumb-separator" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <polyline points="9 18 15 12 9 6"/>
        </svg>
        <button
          class="breadcrumb-link ellipsis"
          @click="navigateToPath(-1)"
          title="Show all breadcrumbs"
        >
          ...
        </button>
      </template>
      <template v-for="(pathId, index) in visibleBreadcrumbs" :key="`breadcrumb-${index}-${pathId}`">
        <svg class="breadcrumb-separator" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <polyline points="9 18 15 12 9 6"/>
        </svg>
        <button
          @click="navigateToPath(getBreadcrumbIndex(index))"
          :class="['breadcrumb-link', { active: getBreadcrumbIndex(index) === navigationPath.length - 1 }]"
        >
          {{ getCategoryByPath(navigationPath.slice(0, getBreadcrumbIndex(index) + 1))?.slotNiceName || getCategoryByPath(navigationPath.slice(0, getBreadcrumbIndex(index) + 1))?.slotName }}
        </button>
      </template>
    </div>

    <!-- Scrollable Content Area -->
    <div class="scrollable-content">
      <!-- Search Results View -->
      <div v-if="hasActiveSearch">
        <div v-if="searchResults.length === 0" class="empty-state">
          <p>No parts found matching "{{ activeSearchQuery }}"</p>
        </div>
        
        <div v-else class="search-results">
          <div
            v-for="result in searchResults"
            :key="result.slotPath"
            class="search-result-section"
            :class="{ collapsed: !openSearchSections[result.slotPath] }"
          >
            <button
              class="result-section-header"
              @click="toggleSearchSection(result.slotPath)"
            >
              <h3>{{ result.slotNiceName || result.slotName }}</h3>
              <svg 
                v-if="openSearchSections[result.slotPath]"
                class="chevron-icon" 
                width="20" 
                height="20" 
                viewBox="0 0 24 24" 
                fill="none" 
                stroke="currentColor" 
                stroke-width="2"
              >
                <polyline points="18 15 12 9 6 15"/>
              </svg>
              <svg 
                v-else
                class="chevron-icon" 
                width="20" 
                height="20" 
                viewBox="0 0 24 24" 
                fill="none" 
                stroke="currentColor" 
                stroke-width="2"
              >
                <polyline points="6 9 12 15 18 9"/>
              </svg>
            </button>
            
            <div v-if="openSearchSections[result.slotPath]" class="result-parts-list">
              <div
                v-for="part in result.parts"
                :key="part.name"
                class="option-item"
              >
                <div class="option-info">
                  <h4>{{ part.niceName || part.name }}</h4>
                </div>
                <div class="option-actions">
                  <span class="option-price">₿ {{ (part.value || 0).toLocaleString() }}</span>
                  <div v-if="part.installed" class="installed-button-wrapper">
                    <button
                      class="btn btn-disabled"
                      @click.stop="toggleRemoveMenu(result.slotPath, part.name)"
                    >
                      Installed
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <polyline points="6 9 12 15 18 9"/>
                      </svg>
                    </button>
                    <div v-if="removeMenuVisible === `${result.slotPath}_${part.name}`" class="remove-menu">
                      <button class="remove-menu-item" @click="removePart(part, result)">
                        Remove
                      </button>
                    </div>
                  </div>
                  <button
                    v-else
                    class="btn btn-primary"
                    @click="installPart(part, result)"
                  >
                    Install
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Normal Navigation View -->
      <div v-else>
        <!-- Parts Options (if available) -->
        <div v-if="currentCategoryOptions && currentCategoryOptions.length > 0" class="parts-options-section" :class="{ collapsed: !isPartsOpen }">
          <button
            class="options-header"
            @click="isPartsOpen = !isPartsOpen"
          >
            <h3>{{ currentCategory?.slotNiceName || currentCategory?.slotName }} Parts</h3>
            <svg 
              v-if="isPartsOpen"
              class="chevron-icon" 
              width="20" 
              height="20" 
              viewBox="0 0 24 24" 
              fill="none" 
              stroke="currentColor" 
              stroke-width="2"
            >
              <polyline points="18 15 12 9 6 15"/>
            </svg>
            <svg 
              v-else
              class="chevron-icon" 
              width="20" 
              height="20" 
              viewBox="0 0 24 24" 
              fill="none" 
              stroke="currentColor" 
              stroke-width="2"
            >
              <polyline points="6 9 12 15 18 9"/>
            </svg>
          </button>
          
          <div v-if="isPartsOpen" class="options-list">
            <div
              v-for="option in currentCategoryOptions"
              :key="option.name"
              class="option-item"
            >
              <div class="option-info">
                <h4>{{ option.niceName || option.name }}</h4>
              </div>
              <div class="option-actions">
                <span class="option-price">₿ {{ (option.value || 0).toLocaleString() }}</span>
                <div v-if="option.installed" class="installed-button-wrapper">
                  <button
                    class="btn btn-disabled"
                    @click.stop="toggleRemoveMenu(currentCategory.path, option.name)"
                  >
                    Installed
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <polyline points="6 9 12 15 18 9"/>
                    </svg>
                  </button>
                  <div v-if="removeMenuVisible === `${currentCategory.path}_${option.name}`" class="remove-menu">
                    <button class="remove-menu-item" @click="removePart(option, currentCategory)">
                      Remove
                    </button>
                  </div>
                </div>
                <div v-else class="install-button-wrapper">
                  <button
                    v-if="!currentCategory.compatibleInventoryParts || currentCategory.compatibleInventoryParts.length === 0"
                    class="btn btn-primary"
                    @click="installPart(option, currentCategory)"
                  >
                    Install
                  </button>
                  <div v-else class="install-dropdown-wrapper">
                    <button
                      class="btn btn-primary"
                      @click.stop="toggleInstallMenu(currentCategory.path, option.name)"
                    >
                      Install
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <polyline points="6 9 12 15 18 9"/>
                      </svg>
                    </button>
                    <div v-if="installMenuVisible === `${currentCategory.path}_${option.name}`" class="install-menu">
                      <button class="install-menu-item" @click="installPart(option, currentCategory)">
                        Install New
                      </button>
                      <div v-for="usedPart in currentCategory.compatibleInventoryParts" :key="usedPart.partId" class="install-menu-item">
                        <button class="install-menu-item-button" @click="installUsedPart(usedPart, currentCategory)">
                          Install Used
                          <span class="mileage-badge">{{ formatMileage(usedPart.mileage) }}</span>
                        </button>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Category/Subcategory List -->
        <div v-if="displayCategories && displayCategories.length > 0" class="categories-list">
          <button
            v-for="category in displayCategories"
            :key="category.id"
            @click="navigateToCategory(category)"
            class="category-item"
          >
            <span class="category-name">{{ category.slotNiceName || category.slotName }}</span>
            <div class="category-right">
              <span class="selected-part-badge">{{ category.partNiceName || '-' }}</span>
              <svg class="chevron-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="9 18 15 12 9 6"/>
              </svg>
            </div>
          </button>
        </div>

        <!-- Empty State -->
        <div v-if="partsTree.length === 0" class="empty-state">
          <p>No parts available for this vehicle</p>
        </div>
        
        <div v-if="partsTree.length > 0 && (!displayCategories || displayCategories.length === 0) && (!currentCategoryOptions || currentCategoryOptions.length === 0)" class="empty-state">
          <p>No parts available in this category</p>
        </div>
      </div>
    </div>
    </template>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { vBngTextInput } from "@/common/directives"
import { useEvents } from "@/services/events"

const store = useBusinessComputerStore()
const events = useEvents()

const searchQuery = ref("")
const activeSearchQuery = ref("")
const navigationPath = ref([])
const isPartsOpen = ref(true)
const partsTree = ref([])
const slotsNiceName = ref({})
const partsNiceName = ref({})
const loading = ref(true) // Start with loading = true to show loading message immediately
const openSearchSections = ref({})
const removeMenuVisible = ref(null)
const installMenuVisible = ref(null)

const hasActiveSearch = computed(() => activeSearchQuery.value.length > 0)

const onSearchFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onSearchBlur = () => {
  try { triggerSearch() } catch (_) {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const triggerSearch = () => {
  activeSearchQuery.value = searchQuery.value.trim()
  // Open all sections by default when searching
  if (hasActiveSearch.value && searchResults.value.length > 0) {
    searchResults.value.forEach(result => {
      openSearchSections.value[result.slotPath] = true
    })
  } else {
    openSearchSections.value = {}
  }
}

const toggleSearchSection = (slotPath) => {
  openSearchSections.value[slotPath] = !openSearchSections.value[slotPath]
}

const clearSearch = () => {
  searchQuery.value = ""
  activeSearchQuery.value = ""
  openSearchSections.value = {}
  try { lua.setCEFTyping(false) } catch (_) {}
}

const searchResults = computed(() => {
  if (!hasActiveSearch.value || !partsTree.value.length) return []
  
  const query = activeSearchQuery.value.toLowerCase()
  const results = []
  const slotMap = {}
  
  // Recursively search through the parts tree
  const searchTree = (nodes) => {
    if (!nodes || !Array.isArray(nodes)) return
    
    nodes.forEach(node => {
      // Check if this slot has parts that match
      if (node.availableParts && node.availableParts.length > 0) {
        const matchingParts = node.availableParts.filter(part => {
          const partName = (part.niceName || part.name || '').toLowerCase()
          return partName.includes(query)
        })
        
        if (matchingParts.length > 0) {
          const slotKey = node.path || node.id
          if (!slotMap[slotKey]) {
            slotMap[slotKey] = {
              slotPath: slotKey,
              slotName: node.slotName || '',
              slotNiceName: node.slotNiceName || node.slotName || '',
              parts: []
            }
            results.push(slotMap[slotKey])
          }
          slotMap[slotKey].parts.push(...matchingParts)
        }
      }
      
      // Recursively search children
      if (node.children && node.children.length > 0) {
        searchTree(node.children)
      }
    })
  }
  
  searchTree(partsTree.value)
  
  return results.map(result => ({
    ...result,
    parts: [...result.parts].sort((a, b) => {
      const nameA = (a.niceName || a.name || '').toLowerCase()
      const nameB = (b.niceName || b.name || '').toLowerCase()
      return nameA.localeCompare(nameB)
    })
  })).sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const getCategoryByPath = (path) => {
  if (!path || path.length === 0) return null
  
  let current = null
  let categories = partsTree.value
  
  for (const pathId of path) {
    current = categories.find(cat => cat.id === pathId)
    if (!current) return null
    if (current.children && current.children.length > 0) {
      categories = current.children
    } else {
      break
    }
  }
  
  return current || null
}

const currentCategory = computed(() => {
  return getCategoryByPath(navigationPath.value)
})

const currentCategoryOptions = computed(() => {
  const parts = currentCategory.value?.availableParts || null
  if (!parts) return null
  return [...parts].sort((a, b) => {
    const nameA = (a.niceName || a.name || '').toLowerCase()
    const nameB = (b.niceName || b.name || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const displayCategories = computed(() => {
  let categories = []
  if (navigationPath.value.length === 0) {
    categories = partsTree.value
  } else {
    const category = getCategoryByPath(navigationPath.value)
    categories = category?.children || []
  }
  return [...categories].sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const visibleBreadcrumbs = computed(() => {
  const maxVisible = 3
  if (navigationPath.value.length <= maxVisible) {
    return navigationPath.value
  }
  return navigationPath.value.slice(-maxVisible)
})

const showEllipsis = computed(() => {
  return navigationPath.value.length > 3
})

const getBreadcrumbIndex = (visibleIndex) => {
  if (!showEllipsis.value) {
    return visibleIndex
  }
  const startIndex = navigationPath.value.length - visibleBreadcrumbs.value.length
  return startIndex + visibleIndex
}

const navigateToCategory = (category) => {
  navigationPath.value.push(category.id)
  isPartsOpen.value = true
}

const navigateToPath = (index) => {
  if (index === -1) {
    navigationPath.value = []
  } else {
    navigationPath.value = navigationPath.value.slice(0, index + 1)
  }
  isPartsOpen.value = true
}

const installPart = async (part, slot) => {
  let slotPath = slot.slotPath || slot.path
  
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }
  
  const normalizedSlot = {
    path: slotPath,
    slotPath: slotPath,
    slotNiceName: slot.slotNiceName || slot.slotName,
    slotName: slot.slotName
  }
  
  await store.addPartToCart(part, normalizedSlot)
}

const toggleRemoveMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (removeMenuVisible.value === menuKey) {
    removeMenuVisible.value = null
  } else {
    removeMenuVisible.value = menuKey
    installMenuVisible.value = null
  }
}

const toggleInstallMenu = (slotPath, partName) => {
  const menuKey = `${slotPath}_${partName}`
  if (installMenuVisible.value === menuKey) {
    installMenuVisible.value = null
  } else {
    installMenuVisible.value = menuKey
    removeMenuVisible.value = null
  }
}

const formatMileage = (miles) => {
  if (!miles || miles === 0) return "0 mi"
  if (miles < 1000) return `${Math.round(miles)} mi`
  return `${(miles / 1000).toFixed(1)}k mi`
}

const installUsedPart = async (usedPart, slot) => {
  installMenuVisible.value = null
  
  const partToAdd = {
    partName: usedPart.name,
    slotPath: slot.path,
    fromInventory: true,
    partId: usedPart.partId
  }
  
  await store.addPartToCart(partToAdd)
}

const removePart = async (part, slot) => {
  removeMenuVisible.value = null
  
  let slotPath = slot.slotPath || slot.path
  
  if (!slotPath.startsWith('/')) {
    slotPath = '/' + slotPath
  }
  if (!slotPath.endsWith('/')) {
    slotPath = slotPath + '/'
  }
  
  await store.removePartBySlotPath(slotPath)
  
  setTimeout(() => {
    loadPartsTree()
  }, 300)
}

const handlePartsTreeData = (data) => {
  if (!data || !data.success) {
    partsTree.value = []
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    return
  }
  
  if (data.vehicleId === store.pulledOutVehicle?.vehicleId && data.businessId === store.businessId) {
    if (data.partsTree) {
      const cacheKey = `${data.businessId}_${data.vehicleId}`
      if (store.partsTreeCache) {
        store.partsTreeCache[cacheKey] = {
          partsTree: data.partsTree,
          slotsNiceName: data.slotsNiceName,
          partsNiceName: data.partsNiceName
        }
      }
      
      slotsNiceName.value = data.slotsNiceName || {}
      partsNiceName.value = data.partsNiceName || {}
      const tree = buildHierarchy(data.partsTree, data.slotsNiceName || {})
      partsTree.value = tree
    } else {
      partsTree.value = []
      slotsNiceName.value = {}
      partsNiceName.value = {}
    }
    loading.value = false
  }
}

const loadPartsTree = async () => {
  if (!store.pulledOutVehicle || !store.businessId) {
    loading.value = false
    return
  }
  
  loading.value = true
  
  store.requestVehiclePartsTree(store.pulledOutVehicle.vehicleId).catch(error => {
    loading.value = false
  })
}

const buildHierarchy = (flatList, slotsNiceNameMap) => {
  const map = {}
  const roots = []
  
  // Helper to get or create a node
  const getOrCreateNode = (pathParts) => {
    const id = pathParts.join('-')
    if (map[id]) {
      return map[id]
    }
    
    const path = '/' + pathParts.join('/')
    const slotName = pathParts[pathParts.length - 1]
    
    // Get slot nice name from mapping
    let slotNiceName = slotName
    if (slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object'
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }
    
    const node = {
      id: id,
      path: path,
      slotName: slotName,
      slotNiceName: slotNiceName,
      partNiceName: '-',
      availableParts: [],
      children: []
    }
    
    map[id] = node
    
    // Recursively create parent if needed
    if (pathParts.length > 1) {
      const parentPathParts = pathParts.slice(0, -1)
      const parent = getOrCreateNode(parentPathParts)
      parent.children.push(node)
    } else {
      roots.push(node)
    }
    
    return node
  }
  
  // First pass: create all nodes from flat list
  flatList.forEach(slot => {
    const pathParts = slot.path.split('/').filter(p => p)
    const id = pathParts.join('-')
    const slotName = pathParts[pathParts.length - 1] || slot.slotName || ''
    
    // Get slot nice name from slot data or mapping
    let slotNiceName = slot.slotNiceName
    if (!slotNiceName && slotName && slotsNiceNameMap[slotName]) {
      slotNiceName = typeof slotsNiceNameMap[slotName] === 'object' 
        ? slotsNiceNameMap[slotName].description || slotsNiceNameMap[slotName]
        : slotsNiceNameMap[slotName]
    }
    if (!slotNiceName && slotName) {
      slotNiceName = slotName
    }
    
    // Get or create the node
    const node = getOrCreateNode(pathParts)
    
    // Update node with slot data
    node.slotName = slotName
    node.slotNiceName = slotNiceName
    node.partNiceName = slot.partNiceName || '-'
    node.availableParts = slot.availableParts || []
  })
  
  return roots.sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || '').toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || '').toLowerCase()
    return nameA.localeCompare(nameB)
  })
}

watch(() => searchResults.value, (newResults) => {
  if (hasActiveSearch.value && newResults.length > 0) {
    newResults.forEach(result => {
      if (openSearchSections.value[result.slotPath] === undefined) {
        openSearchSections.value[result.slotPath] = true
      }
    })
  }
}, { immediate: true })

watch(() => store.pulledOutVehicle, (newVehicle, oldVehicle) => {
  if (!newVehicle) {
    partsTree.value = []
    navigationPath.value = []
    slotsNiceName.value = {}
    partsNiceName.value = {}
    loading.value = false
    store.clearCart()
  } else {
    navigationPath.value = []
  }
  // Don't load data here - wait for onMounted
})

// Watch for tab changes and reload parts tree to reflect the new tab's cart
watch(() => store.activeTabId, async (newTabId, oldTabId) => {
  if (newTabId && newTabId !== oldTabId && store.pulledOutVehicle && store.vehicleView === 'parts') {
    if (store.isCurrentTabApplied) {
      return
    }
    setTimeout(() => {
      if (!store.isCurrentTabApplied) {
        loadPartsTree()
      }
    }, 600)
  }
})

const handleClickOutside = (e) => {
  if (!e.target.closest('.installed-button-wrapper')) {
    removeMenuVisible.value = null
  }
  if (!e.target.closest('.install-dropdown-wrapper')) {
    installMenuVisible.value = null
  }
}

onMounted(() => {
  // Register event listener for parts tree data
  events.on('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  
  // Close remove menu when clicking outside
  document.addEventListener('click', handleClickOutside)
  
  // Wait for UI animation to complete (600ms) before requesting parts tree data
  // This ensures vehicle spawning doesn't happen until animation is finished
  requestAnimationFrame(() => {
    setTimeout(() => {
      if (store.pulledOutVehicle && store.vehicleView === 'parts') {
        loadPartsTree()
      }
    }, 600) // Wait for full animation to complete
  })
})

onBeforeUnmount(() => {
  // Clean up event listener
  events.off('businessComputer:onVehiclePartsTree', handlePartsTreeData)
  document.removeEventListener('click', handleClickOutside)
})
</script>

<style scoped lang="scss">
.parts-customization {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  gap: 1em;
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

.breadcrumb-nav {
  display: flex;
  align-items: center;
  gap: 0.5em;
  flex-shrink: 0;
  font-size: 0.875em;
  overflow: hidden;
  min-width: 0;
  
  .breadcrumb-link {
    color: rgba(245, 73, 0, 1);
    background: transparent;
    border: none;
    cursor: pointer;
    transition: color 0.2s;
    padding: 0;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 10em;
    flex-shrink: 1;
    
    &:hover {
      color: rgba(245, 73, 0, 0.8);
    }
    
    &.active {
      color: white;
      cursor: default;
    }
    
    &.ellipsis {
      max-width: 1.5em;
      flex-shrink: 0;
    }
  }
  
  .breadcrumb-separator {
    color: rgba(255, 255, 255, 0.5);
    flex-shrink: 0;
  }
}

.scrollable-content {
  flex: 1;
  overflow-y: auto;
  min-height: 0;
  
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

.parts-options-section {
  margin-bottom: 1.5em;
  flex-shrink: 0;
  
  &.collapsed {
    margin-bottom: 0.75em;
  }
}

.options-header {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5em 0.75em;
  background: transparent;
  border: none;
  cursor: pointer;
  transition: background 0.2s;
  margin-bottom: 0.75em;
  
  &:hover {
    background: rgba(23, 23, 23, 0.5);
    border-radius: 0.25em;
  }
  
  h3 {
    margin: 0;
    color: white;
    font-size: 1em;
    font-weight: 600;
  }
  
  .chevron-icon {
    color: rgba(255, 255, 255, 0.4);
    flex-shrink: 0;
  }
}

.options-list {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.option-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75em;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  transition: border-color 0.2s;
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
  
  .option-info {
    flex: 1;
    min-width: 0;
    
    h4 {
      margin: 0;
      color: white;
      font-size: 0.875em;
      font-weight: 600;
      text-align: left;
      word-wrap: break-word;
    }
  }
  
  .option-actions {
    display: flex;
    align-items: center;
    gap: 0.75em;
    flex-shrink: 0;
    
    .option-price {
      color: rgba(245, 73, 0, 1);
      font-size: 0.875em;
      font-weight: 500;
      min-width: 6em;
      text-align: right;
    }
  }
}

.categories-list {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.search-results {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.search-result-section {
  margin-bottom: 1.5em;
  flex-shrink: 0;
  
  &.collapsed {
    margin-bottom: 0;
    
    .result-section-header {
      margin-bottom: 0;
    }
  }
  
  .result-section-header {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.5em 0.75em;
    background: transparent;
    border: none;
    cursor: pointer;
    transition: background 0.2s;
    margin-bottom: 0.75em;
    
    &:hover {
      background: rgba(23, 23, 23, 0.5);
      border-radius: 0.25em;
    }
    
    h3 {
      margin: 0;
      color: white;
      font-size: 1em;
      font-weight: 600;
    }
    
    .chevron-icon {
      color: rgba(255, 255, 255, 0.4);
      flex-shrink: 0;
    }
  }
  
  .result-parts-list {
    display: flex;
    flex-direction: column;
    gap: 0.75em;
  }
}

.category-item {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.625em 0.75em;
  background: transparent;
  border: none;
  cursor: pointer;
  transition: background 0.2s;
  border-radius: 0.25em;
  
  &:hover {
    background: rgba(23, 23, 23, 0.5);
  }
  
  .category-name {
    color: white;
    font-size: 0.875em;
    text-align: left;
    word-wrap: break-word;
  }
  
  .category-right {
    display: flex;
    align-items: center;
    gap: 0.5em;
    
    .selected-part-badge {
      padding: 0.25em 0.75em;
      background: rgba(26, 26, 26, 1);
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 0.25em;
      color: rgba(255, 255, 255, 0.7);
      font-size: 0.875em;
      min-width: 8.75em;
      text-align: center;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    
    .chevron-icon {
      color: rgba(255, 255, 255, 0.4);
      flex-shrink: 0;
      transition: color 0.2s;
    }
  }
  
  &:hover .category-right .chevron-icon {
    color: rgba(245, 73, 0, 1);
  }
}

.empty-state,
.loading-state {
  padding: 3em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
  
  p {
    margin: 0;
  }
}

.btn {
  padding: 0.5em 1em;
  border-radius: 0.375em;
  font-size: 0.875em;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  flex-shrink: 0;
  
  &.btn-primary {
    background: rgba(55, 55, 55, 1);
    color: white;
    
    &:hover:not(:disabled) {
      background: rgba(245, 73, 0, 1);
    }
  }
  
  &.btn-disabled {
    background: rgba(55, 55, 55, 1);
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 0.5em;
    
    svg {
      width: 12px;
      height: 12px;
      transition: transform 0.2s;
    }
    
    &:hover {
      background: rgba(65, 65, 65, 1);
    }
  }
}

.installed-button-wrapper {
  position: relative;
  display: inline-block;
}

.install-button-wrapper {
  position: relative;
  display: inline-block;
}

.install-dropdown-wrapper {
  position: relative;
  display: inline-block;
}

.install-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 0.25em;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.375em;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  z-index: 1000;
  min-width: 180px;
  overflow: hidden;
}

.install-menu-item {
  display: block;
  width: 100%;
}

.install-menu-item-button {
  width: 100%;
  padding: 0.75em 1em;
  background: transparent;
  border: none;
  color: white;
  text-align: left;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  transition: background 0.2s;
  
  &:hover {
    background: rgba(245, 73, 0, 0.2);
  }
  
  &:first-child {
    border-top-left-radius: 0.375em;
    border-top-right-radius: 0.375em;
  }
  
  &:last-child {
    border-bottom-left-radius: 0.375em;
    border-bottom-right-radius: 0.375em;
  }
}

.install-menu-item:first-child button {
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.mileage-badge {
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.6);
  background: rgba(255, 255, 255, 0.1);
  padding: 0.25em 0.5em;
  border-radius: 0.25em;
}

.remove-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 0.25em;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.375em;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  z-index: 1000;
  min-width: 120px;
  overflow: hidden;
  
  .remove-menu-item {
    width: 100%;
    padding: 0.75em 1em;
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.875em;
    cursor: pointer;
    text-align: left;
    transition: background 0.2s;
    
    &:hover {
      background: rgba(245, 73, 0, 0.3);
      color: white;
    }
  }
}
</style>



