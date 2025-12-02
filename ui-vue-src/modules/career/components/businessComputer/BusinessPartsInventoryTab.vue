<template>
  <div class="parts-inventory-tab">
    <div class="tab-header">
      <h2>Parts Inventory</h2>
      <p>Manage your used car parts collection</p>
    </div>
    
    <div class="parts-stats">
      <div class="stat">
        <span class="label">Total Parts</span>
        <span class="value">{{ Array.isArray(store.parts) ? store.parts.length : 0 }}</span>
      </div>
      <div class="stat">
        <span class="label">Total Value</span>
        <span class="value">${{ formatPrice(totalValue) }}</span>
      </div>
    </div>
    
    <div class="parts-list">
      <div
        v-for="part in groupedParts"
        :key="part.vehicle"
        class="parts-group-card"
      >
        <div class="card-header">
          <h3>{{ part.vehicle }}</h3>
        </div>
        <div class="card-content">
          <div class="parts-items">
            <div
              v-for="item in part.parts"
              :key="item.partId"
              class="part-item"
            >
              <div class="part-info">
                <h4>{{ item.name }}</h4>
                <span class="part-id">ID: {{ item.partId }}</span>
              </div>
              <div class="part-details">
                <span class="condition" :class="getConditionClassFromText(item.condition)">
                  {{ item.condition }}
                </span>
                <span class="mileage">{{ item.mileage.toLocaleString() }} mi</span>
                <span class="price">${{ formatPrice(item.price || item.value || 0) }}</span>
              </div>
              <button class="btn btn-primary" disabled title="Selling disabled">Sell Part</button>
            </div>
          </div>
        </div>
      </div>
    </div>
    
    <div v-if="!Array.isArray(store.parts) || store.parts.length === 0" class="empty-state">
      No parts in inventory
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { formatPrice, getConditionClassFromText } from "../../utils/businessUtils"

const store = useBusinessComputerStore()

const totalValue = computed(() => {
  const parts = Array.isArray(store.parts) ? store.parts : []
  if (parts.length === 0) return 0
  const total = parts.reduce((sum, part) => sum + (part.price || part.value || 0), 0)
  return Math.round(total * 100) / 100
})

const groupedParts = computed(() => {
  const parts = Array.isArray(store.parts) ? store.parts : []
  const groups = {}
  parts.forEach(part => {
    const vehicle = part.compatibleVehicle || "Unknown"
    if (!groups[vehicle]) {
      groups[vehicle] = { vehicle, parts: [] }
    }
    groups[vehicle].parts.push(part)
  })
  return Object.values(groups)
})
</script>

<style scoped lang="scss">
.parts-inventory-tab {
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

.parts-stats {
  display: flex;
  gap: 1em;
  
  .stat {
    padding: 1em;
    background: rgba(23, 23, 23, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.5em;
    display: flex;
    flex-direction: column;
    
    .label {
      color: rgba(255, 255, 255, 0.6);
      font-size: 0.875em;
    }
    
    .value {
      color: rgba(245, 73, 0, 1);
      font-size: 1.25em;
      font-weight: 500;
    }
  }
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
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125em;
    font-weight: 600;
  }
}

.card-content {
  padding: 1.5em;
}

.parts-items {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
}

.part-item {
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 0.75em;
  background: rgba(26, 26, 26, 0.5);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 0.25em;
}

.part-info {
  flex: 1;
  
  h4 {
    margin: 0 0 0.25em 0;
    color: white;
    font-size: 0.875em;
    font-weight: 600;
  }
  
  .part-id {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.75em;
  }
}

.part-details {
  display: flex;
  align-items: center;
  gap: 1em;
  
  .condition {
    padding: 0.25em 0.5em;
    border-radius: 0.25em;
    font-size: 0.75em;
    font-weight: 500;
    
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
  
  .mileage {
    color: rgba(245, 73, 0, 1);
    font-size: 0.875em;
  }
  
  .price {
    color: rgba(34, 197, 94, 1);
    font-weight: 500;
    font-size: 0.875em;
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
  color: rgba(255, 255, 255, 0.5);
}
</style>
