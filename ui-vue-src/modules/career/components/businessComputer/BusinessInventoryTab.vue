<template>
  <div class="inventory-tab">
    <div class="tab-header">
      <h2>Parts Inventory</h2>
      <p>Manage your used car parts collection</p>
    </div>
    
    <!-- Search Bar and Stats -->
    <div class="search-stats-bar">
      <div class="search-section">
        <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="8"/>
          <path d="m21 21-4.35-4.35"/>
        </svg>
        <input
          v-model="searchQuery"
          type="text"
          placeholder="Search by part name or vehicle..."
          class="search-input"
        />
      </div>
      <div class="stats-section">
        <div class="stat-card">
          <p class="stat-label">Total Parts</p>
          <p class="stat-value">{{ filteredParts.length }}</p>
        </div>
        <div class="stat-card">
          <p class="stat-label">Total Value</p>
          <p class="stat-value green">${{ totalValue.toLocaleString() }}</p>
        </div>
        <button class="btn btn-primary sell-all-btn" disabled title="Selling disabled">
          Sell All Parts
        </button>
      </div>
    </div>

    <!-- Parts Grouped by Vehicle -->
    <div class="parts-groups">
      <div v-if="Object.keys(groupedParts).length === 0 && searchQuery.trim()" class="empty-state">
        <p>No parts found matching your search.</p>
      </div>
      
      <div
        v-for="[vehicle, vehicleParts] in Object.entries(groupedParts)"
        :key="vehicle"
        class="parts-group-card"
      >
        <div class="card-header" @click="toggleSection(vehicle)">
          <div class="header-left">
            <h3>{{ vehicle }}</h3>
            <span class="parts-count-badge">{{ vehicleParts.length }} {{ vehicleParts.length === 1 ? 'Part' : 'Parts' }}</span>
          </div>
          <svg 
            v-if="openSections[vehicle] !== false" 
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
        </div>
        
        <div v-if="openSections[vehicle] !== false" class="card-content">
          <div class="parts-list">
            <div
              v-for="part in vehicleParts"
              :key="part.partId"
              class="part-item"
            >
              <div class="part-info">
                <h4>{{ part.name }}</h4>
                <p class="part-id">ID: {{ part.partId }}</p>
              </div>

              <span class="condition-badge" :class="getConditionClass(part.condition)">
                {{ part.condition }}
              </span>

              <div class="mileage-display">
                <svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="12" cy="12" r="10"/>
                  <polyline points="12 6 12 12 16 14"/>
                </svg>
                <span>{{ (part.mileage || 0).toLocaleString() }} mi</span>
              </div>

              <div class="price-display">
                <svg class="icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <line x1="12" y1="1" x2="12" y2="23"/>
                  <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>
                </svg>
                <span>${{ ((part.price || part.value || 0)).toLocaleString() }}</span>
              </div>

              <button class="btn btn-primary sell-part-btn" disabled title="Selling disabled">
                Sell Part
              </button>
            </div>
          </div>
          
          <div class="sell-all-footer">
            <button class="btn btn-primary sell-all-vehicle-btn" disabled title="Selling disabled">
              Sell All {{ vehicle }} Parts
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const store = useBusinessComputerStore()
const searchQuery = ref('')
const openSections = ref({})

const filteredParts = computed(() => {
  try {
    const parts = Array.isArray(store.parts) ? store.parts : []
    if (!searchQuery.value.trim()) {
      return parts
    }
    const query = searchQuery.value.toLowerCase()
    return parts.filter(part => 
      (part.name && part.name.toLowerCase().includes(query)) ||
      (part.compatibleVehicle && part.compatibleVehicle.toLowerCase().includes(query))
    )
  } catch (error) {
    return []
  }
})

const groupedParts = computed(() => {
  try {
    const parts = Array.isArray(filteredParts.value) ? filteredParts.value : []
    const groups = {}
    parts.forEach(part => {
      if (!part) return
      const vehicle = part.compatibleVehicle || "Unknown"
      if (!groups[vehicle]) {
        groups[vehicle] = []
      }
      groups[vehicle].push(part)
    })
    return groups
  } catch (error) {
    return {}
  }
})

const totalValue = computed(() => {
  const parts = Array.isArray(filteredParts.value) ? filteredParts.value : []
  if (parts.length === 0) return 0
  return parts.reduce((sum, part) => sum + (part.price || part.value || 0), 0)
})

const toggleSection = (vehicle) => {
  openSections.value[vehicle] = openSections.value[vehicle] === false ? true : false
}

const getConditionClass = (condition) => {
  const classes = {
    'Excellent': 'condition-excellent',
    'Good': 'condition-good',
    'Fair': 'condition-fair',
    'Poor': 'condition-poor'
  }
  return classes[condition] || 'condition-good'
}

</script>

<style scoped lang="scss">
.inventory-tab {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.tab-header {
  h2 {
    margin: 0 0 0.5em 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.5em;
    font-weight: 600;
  }
  
  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.875em;
  }
}

.search-stats-bar {
  display: flex;
  flex-direction: column;
  gap: 1em;
  
  @media (min-width: 768px) {
    flex-direction: row;
    align-items: center;
  }
}

.search-section {
  position: relative;
  flex: 1;
  
  .search-icon {
    position: absolute;
    left: 0.875em;
    top: 50%;
    transform: translateY(-50%);
    color: rgba(255, 255, 255, 0.4);
    width: 1em;
    height: 1em;
    pointer-events: none;
  }
  
  .search-input {
    width: 100%;
    padding: 0.75em 1em 0.75em 2.5em;
    height: 3.25em;
    background: rgba(23, 23, 23, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.5em;
    color: white;
    font-size: 0.875em;
    
    &::placeholder {
      color: rgba(255, 255, 255, 0.5);
    }
    
    &:focus {
      outline: none;
      border-color: rgba(245, 73, 0, 0.5);
    }
  }
}

.stats-section {
  display: flex;
  gap: 1em;
  align-items: center;
  flex-wrap: wrap;
}

.stat-card {
  padding: 0.75em 1em;
  height: 3.25em;
  display: flex;
  flex-direction: column;
  justify-content: center;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  min-width: 7em;
  
  .stat-label {
    margin: 0;
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.75em;
  }
  
  .stat-value {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1em;
    font-weight: 600;
    
    &.green {
      color: rgba(34, 197, 94, 1);
    }
  }
}

.sell-all-btn {
  height: 3.25em;
  padding: 0 1.5em;
  white-space: nowrap;
}

.parts-groups {
  display: flex;
  flex-direction: column;
  gap: 1.5em;
}

.parts-group-card {
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(245, 73, 0, 0.3);
  border-radius: 0.5em;
  overflow: hidden;
}

.card-header {
  padding: 1em 1.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.3);
  display: flex;
  align-items: center;
  justify-content: space-between;
  cursor: pointer;
  transition: all 0.2s;
  
  &:hover {
    background: rgba(23, 23, 23, 0.5);
    
    h3 {
      color: rgba(245, 73, 0, 1);
    }
  }
  
  .header-left {
    display: flex;
    align-items: center;
    gap: 0.75em;
  }
  
  h3 {
    margin: 0;
    color: white;
    font-size: 1.125em;
    font-weight: 600;
    transition: color 0.2s;
  }
  
  .parts-count-badge {
    padding: 0.25em 0.5em;
    background: rgba(245, 73, 0, 0.2);
    color: rgba(245, 73, 0, 1);
    border: 1px solid rgba(245, 73, 0, 0.5);
    border-radius: 0.25em;
    font-size: 0.75em;
    font-weight: 500;
  }
  
  .chevron-icon {
    color: rgba(255, 255, 255, 0.6);
    flex-shrink: 0;
  }
}

.card-content {
  padding: 1.5em;
  display: flex;
  flex-direction: column;
  gap: 1em;
}

.parts-list {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  max-height: 25em;
  overflow-y: auto;
  padding-right: 0.5em;
  
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

.part-item {
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 0.75em;
  background: rgba(26, 26, 26, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  transition: border-color 0.2s;
  
  &:hover {
    border-color: rgba(245, 73, 0, 0.5);
  }
}

.part-info {
  flex: 1;
  min-width: 0;
  
  h4 {
    margin: 0 0 0.25em 0;
    color: white;
    font-size: 0.875em;
    font-weight: 600;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  
  .part-id {
    margin: 0;
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.75em;
  }
}

.condition-badge {
  padding: 0.25em 0.5em;
  border-radius: 0.25em;
  font-size: 0.75em;
  font-weight: 500;
  white-space: nowrap;
  
  &.condition-excellent {
    background: rgba(34, 197, 94, 0.2);
    color: rgba(34, 197, 94, 1);
    border: 1px solid rgba(34, 197, 94, 0.5);
  }
  
  &.condition-good {
    background: rgba(59, 130, 246, 0.2);
    color: rgba(59, 130, 246, 1);
    border: 1px solid rgba(59, 130, 246, 0.5);
  }
  
  &.condition-fair {
    background: rgba(234, 179, 8, 0.2);
    color: rgba(234, 179, 8, 1);
    border: 1px solid rgba(234, 179, 8, 0.5);
  }
  
  &.condition-poor {
    background: rgba(239, 68, 68, 0.2);
    color: rgba(239, 68, 68, 1);
    border: 1px solid rgba(239, 68, 68, 0.5);
  }
}

.mileage-display,
.price-display {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.375em 1em;
  background: rgba(23, 23, 23, 0.5);
  border-radius: 0.25em;
  min-width: 8.75em;
  
  .icon {
    color: rgba(255, 255, 255, 0.4);
    flex-shrink: 0;
  }
  
  span {
    color: rgba(245, 73, 0, 1);
    font-size: 0.875em;
    white-space: nowrap;
  }
}

.price-display span {
  color: rgba(34, 197, 94, 1);
}

.sell-part-btn {
  padding: 0.5em 1em;
  white-space: nowrap;
}

.sell-all-footer {
  display: flex;
  justify-content: flex-end;
  padding-top: 0.5em;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
}

.sell-all-vehicle-btn {
  padding: 0.5em 1.5em;
}

.btn {
  border-radius: 0.375em;
  font-size: 0.875em;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s;
  border: none;
  
  &.btn-primary {
    background: rgba(245, 73, 0, 1);
    color: white;
    
    &:hover {
      background: rgba(245, 73, 0, 0.9);
    }
  }
}

.empty-state {
  padding: 3em;
  text-align: center;
  background: rgba(23, 23, 23, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.5em;
  
  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.5);
  }
}
</style>

