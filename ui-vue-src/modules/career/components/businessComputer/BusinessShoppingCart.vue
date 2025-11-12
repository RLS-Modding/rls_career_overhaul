<template>
  <div class="business-shopping-cart" :class="{ expanded }" v-bng-blur>
    <div class="cart-header">
      <h3>Shopping Cart</h3>
      <button class="expand-toggle" @click="expanded = !expanded">
        <svg 
          class="chevron-icon" 
          width="20" 
          height="20" 
          viewBox="0 0 24 24" 
          fill="none" 
          stroke="currentColor" 
          stroke-width="2"
          :class="{ rotated: !expanded }"
        >
          <polyline points="6 9 12 15 18 9"/>
        </svg>
      </button>
    </div>
    
    <transition name="cart-collapse">
      <div v-if="expanded" class="cart-main">
      <div class="cart-tabs">
        <div class="tabs-list">
          <button
            v-for="tab in store.cartTabs"
            :key="tab.id"
            class="tab-button"
            :class="{ active: tab.id === store.activeTabId }"
            @click="store.switchTab(tab.id)"
          >
            {{ tab.name }}
            <button
              v-if="store.cartTabs.length > 1"
              class="tab-close"
              @click.stop="store.deleteTab(tab.id)"
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
            </button>
          </button>
          <button class="tab-add" @click="store.createNewTab" title="New Build">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <line x1="12" y1="5" x2="12" y2="19"/>
              <line x1="5" y1="12" x2="19" y2="12"/>
            </svg>
          </button>
        </div>
      </div>
      <div class="cart-list">
        <div v-if="partsItems.length === 0 && tuningItems.length === 0" class="empty-cart">
          <p>Cart is empty</p>
        </div>
        
        <template v-if="partsItems.length > 0">
          <div class="cart-section-header">Parts</div>
          <PartsTreeItem
            v-for="node in store.partsTree"
            :key="node.id"
            :node="node"
            :level="0"
            @remove="store.removePartFromCart"
          />
        </template>
        
        <template v-if="tuningItems.length > 0">
          <div class="cart-section-header">Tuning</div>
          <div v-for="item in tuningItems" :key="item.varName" class="cart-item">
            <button class="remove-button" @click="store.removeTuningFromCart(item.varName)">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
            </button>
            <div class="item-info">
              <div class="item-name">{{ item.title || item.varName }}</div>
              <div class="item-slot">{{ item.originalValue?.toFixed(2) }} → {{ item.value?.toFixed(2) }}</div>
            </div>
            <div class="item-price">${{ (item.price || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}</div>
          </div>
        </template>
      </div>
      
      <div class="cart-footer">
        <div v-if="store.originalPower !== null && store.currentPower !== null" class="power-weight-stats">
          <div class="stats-container">
            <div class="stat-row">
              <div class="stat-label-col">Power:</div>
              <div class="stat-value-col">{{ Math.round(store.originalPower) }} kW</div>
              <div class="stat-arrow-col">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M5 12h14M12 5l7 7-7 7"/>
                </svg>
              </div>
              <div class="stat-value-col">{{ Math.round(store.currentPower) }} kW</div>
            </div>
            <div class="stat-row">
              <div class="stat-label-col">Weight:</div>
              <div class="stat-value-col">{{ Math.round(store.originalWeight) }} kg</div>
              <div class="stat-arrow-col">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M5 12h14M12 5l7 7-7 7"/>
                </svg>
              </div>
              <div class="stat-value-col">{{ Math.round(store.currentWeight) }} kg</div>
            </div>
            <div class="stat-row">
              <div class="stat-label-col">Power/Weight:</div>
              <div class="stat-value-col">{{ store.originalPowerToWeightRatio ? store.originalPowerToWeightRatio.toFixed(2) : '-' }}</div>
              <div class="stat-arrow-col">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M5 12h14M12 5l7 7-7 7"/>
                </svg>
              </div>
              <div class="stat-value-col">{{ store.powerToWeightRatio ? store.powerToWeightRatio.toFixed(2) : '-' }}</div>
            </div>
          </div>
        </div>
        <div class="cart-total">
          <span>Total:</span>
          <span class="total-amount">${{ totalCost.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}</span>
        </div>
        <div class="cart-buttons">
          <button class="btn btn-secondary" @click="cancel">Cancel</button>
          <button 
            class="btn btn-primary" 
            :disabled="totalCost === 0 || totalCost > businessBalance"
            @click="purchase"
          >
            Purchase
          </button>
        </div>
      </div>
      </div>
    </transition>
    
    <transition name="cart-collapse">
      <div v-if="!expanded" class="cart-collapsed">
        <div class="cart-summary">
          <span>{{ totalItems }} item{{ totalItems !== 1 ? 's' : '' }}</span>
          <span class="summary-total">${{ totalCost.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}</span>
        </div>
      </div>
    </transition>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"
import { vBngBlur } from "@/common/directives"
import PartsTreeItem from "./PartsTreeItem.vue"

const store = useBusinessComputerStore()
const events = useEvents()

// Handle power/weight data from Lua
const handlePowerWeightData = (data) => {
  store.handlePowerWeightData(data)
}

const expanded = ref(false)
const businessBalance = ref(0)

const partsItems = computed(() => store.partsCart || [])
const tuningItems = computed(() => store.tuningCart || [])

const tuningCost = computed(() => {
  return store.tuningCost || 0
})

const totalCost = computed(() => {
  return store.getCartTotal || 0
})

const totalItems = computed(() => {
  return partsItems.value.length + (tuningItems.value.length > 0 ? 1 : 0)
})

const loadBalance = async () => {
  if (!store.businessType || !store.businessId) {
    businessBalance.value = 0
    return
  }
  
  try {
    const balance = await lua.career_modules_business_businessComputer.getBusinessAccountBalance(
      store.businessType,
      store.businessId
    )
    businessBalance.value = balance || 0
  } catch (error) {
    console.error("Failed to load business account balance:", error)
    businessBalance.value = 0
  }
}

const handleAccountUpdate = (data) => {
  if (!data || !store.businessType || !store.businessId) return
  
  const accountId = "business_" + store.businessType + "_" + store.businessId
  
  if (data.accountId === accountId) {
    businessBalance.value = data.balance || 0
  }
}

const purchase = async () => {
  if (totalCost.value === 0 || totalCost.value > businessBalance.value) return
  
  try {
    const accountId = "business_" + store.businessType + "_" + store.businessId
    const success = await lua.career_modules_business_businessComputer.purchaseCartItems(
      store.businessId,
      accountId,
      {
        parts: partsItems.value,
        tuning: tuningItems.value
      }
    )
    
    if (success) {
      // Clear cart and reset vehicle to baseline after purchase
      store.clearCart()
      expanded.value = false
      
      // Reset vehicle to baseline (purchased parts are now saved, so baseline includes them)
      if (store.businessId && store.pulledOutVehicle?.vehicleId) {
        try {
          await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
            store.businessId,
            store.pulledOutVehicle.vehicleId
          )
          // Re-initialize preview vehicle with new baseline (includes purchased parts)
          await lua.career_modules_business_businessComputer.initializePreviewVehicle(
            store.businessId,
            store.pulledOutVehicle.vehicleId
          )
          // Power/weight will be updated automatically by Lua after vehicle replacement
        } catch (error) {
          console.error("Failed to reset vehicle after purchase:", error)
        }
      }
      
      await loadBalance()
    }
  } catch (error) {
    console.error("Failed to purchase cart items:", error)
  }
}

const cancel = async () => {
  // Reset vehicle to original state before clearing cart
  if (store.businessId && store.pulledOutVehicle?.vehicleId) {
    try {
      await lua.career_modules_business_businessComputer.resetVehicleToOriginal(
        store.businessId,
        store.pulledOutVehicle.vehicleId
      )
      // Power/weight will be updated automatically by Lua after vehicle replacement
    } catch (error) {
      console.error("Failed to reset vehicle to original:", error)
    }
  }
  
  store.clearCart()
  expanded.value = false
}

watch([() => store.businessType, () => store.businessId], () => {
  loadBalance()
}, { immediate: true })

// Power/weight updates are now handled entirely by Lua - no need for this handler

onMounted(() => {
  // Register event listener for power/weight data (sent automatically by Lua)
  events.on('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
})

onBeforeUnmount(() => {
  // Clean up event listener
  events.off('businessComputer:onVehiclePowerWeight', handlePowerWeightData)
})

watch(() => store.vehicleView, (newView) => {
  if (newView !== 'parts' && newView !== 'tuning') {
    expanded.value = false
  }
})

onMounted(async () => {
  events.on('bank:onAccountUpdate', handleAccountUpdate)
  loadBalance()
  
  // Initialize cart when component mounts if vehicle is already pulled out
  // Delay until UI animation completes (600ms) to avoid vehicle spawning during animation
  if (store.pulledOutVehicle && (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
    setTimeout(async () => {
      // Double-check we're still in the vehicle view (user might have switched away)
      if (store.vehicleView === 'parts' || store.vehicleView === 'tuning') {
        await store.initializeCartForVehicle()
      }
    }, 600)
  }
})

watch(() => store.pulledOutVehicle, async (newVehicle) => {
  if (newVehicle && (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
    // Delay until UI animation completes (600ms) to avoid vehicle spawning during animation
    setTimeout(async () => {
      // Double-check we're still in the vehicle view and vehicle is still pulled out
      if (newVehicle && (store.vehicleView === 'parts' || store.vehicleView === 'tuning')) {
        await store.initializeCartForVehicle()
      }
    }, 600)
  }
}, { immediate: true })

onBeforeUnmount(() => {
  events.off('bank:onAccountUpdate', handleAccountUpdate)
})
</script>

<style scoped lang="scss">
.business-shopping-cart {
  position: fixed;
  bottom: 2em;
  right: 2em;
  width: 28em;
  max-height: 40em;
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.4);
  border-radius: 0.5em;
  z-index: 2000;
  display: flex;
  flex-direction: column;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  
  &.expanded {
    max-height: 40em;
  }
}

.cart-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1em 1.5em;
  border-bottom: 2px solid rgba(245, 73, 0, 0.4);
  
  h3 {
    margin: 0;
    color: rgba(245, 73, 0, 1);
    font-size: 1.125em;
    font-weight: 600;
  }
  
  .expand-toggle {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.6);
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;
    
    &:hover {
      color: rgba(245, 73, 0, 1);
    }
    
    svg {
      width: 20px;
      height: 20px;
    }
    
    .chevron-icon {
      transition: transform 0.3s ease;
      
      &.rotated {
        transform: rotate(180deg);
      }
    }
  }
}

.cart-collapsed {
  padding: 1em 1.5em;
  
  .cart-summary {
    display: flex;
    justify-content: space-between;
    align-items: center;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.875em;
    
    .summary-total {
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-size: 1.125em;
    }
  }
}

.cart-main {
  display: flex;
  flex-direction: column;
  flex: 1;
  overflow: hidden;
}

.cart-tabs {
  padding: 0.75em 1em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(23, 23, 23, 0.5);
  
  .tabs-list {
    display: flex;
    gap: 0.5em;
    align-items: center;
    overflow-x: auto;
    
    &::-webkit-scrollbar {
      height: 4px;
    }
    
    &::-webkit-scrollbar-track {
      background: rgba(0, 0, 0, 0.2);
    }
    
    &::-webkit-scrollbar-thumb {
      background: rgba(255, 255, 255, 0.1);
      border-radius: 2px;
    }
  }
  
  .tab-button {
    display: flex;
    align-items: center;
    gap: 0.5em;
    padding: 0.5em 0.75em;
    background: rgba(55, 55, 55, 1);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25em;
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.875em;
    cursor: pointer;
    transition: all 0.2s;
    white-space: nowrap;
    flex-shrink: 0;
    
    &:hover {
      background: rgba(75, 75, 75, 1);
      border-color: rgba(245, 73, 0, 0.5);
    }
    
    &.active {
      background: rgba(245, 73, 0, 1);
      border-color: rgba(245, 73, 0, 1);
      color: white;
    }
    
    .tab-close {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 0.125em;
      background: transparent;
      border: none;
      color: inherit;
      cursor: pointer;
      opacity: 0.6;
      transition: opacity 0.2s;
      flex-shrink: 0;
      
      &:hover {
        opacity: 1;
      }
      
      svg {
        width: 12px;
        height: 12px;
      }
    }
  }
  
  .tab-add {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0.5em;
    background: rgba(55, 55, 55, 1);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 0.25em;
    color: rgba(255, 255, 255, 0.7);
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
    
    &:hover {
      background: rgba(75, 75, 75, 1);
      border-color: rgba(245, 73, 0, 0.5);
      color: rgba(245, 73, 0, 1);
    }
    
    svg {
      width: 16px;
      height: 16px;
    }
  }
}

.cart-collapse-enter-active,
.cart-collapse-leave-active {
  transition: max-height 0.3s ease, opacity 0.3s ease;
  overflow: hidden;
}

.cart-collapse-enter-from {
  max-height: 0;
  opacity: 0;
}

.cart-collapse-enter-to {
  max-height: 40em;
  opacity: 1;
}

.cart-collapse-leave-from {
  max-height: 40em;
  opacity: 1;
}

.cart-collapse-leave-to {
  max-height: 0;
  opacity: 0;
}

.cart-list {
  flex: 1;
  overflow-y: auto;
  padding: 1em;
  
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

.empty-cart {
  padding: 2em;
  text-align: center;
  color: rgba(255, 255, 255, 0.5);
}

.cart-section-header {
  padding: 0.5em 0;
  color: rgba(245, 73, 0, 1);
  font-weight: 600;
  font-size: 0.875em;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  margin-bottom: 0.5em;
}

.cart-item {
  display: flex;
  align-items: center;
  gap: 1em;
  padding: 0.75em 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  
  .remove-button {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s;
    flex-shrink: 0;
    
    &:hover {
      color: rgba(255, 0, 0, 0.8);
    }
    
    svg {
      width: 16px;
      height: 16px;
    }
  }
  
  .item-info {
    flex: 1;
    min-width: 0;
    
    .item-name {
      color: rgba(255, 255, 255, 0.9);
      font-size: 0.875em;
      font-weight: 500;
      margin-bottom: 0.25em;
    }
    
    .item-slot {
      color: rgba(255, 255, 255, 0.5);
      font-size: 0.75em;
    }
  }
  
  .item-price {
    color: rgba(245, 73, 0, 1);
    font-weight: 600;
    font-size: 0.875em;
    flex-shrink: 0;
    font-family: 'Courier New', monospace;
  }
}

.cart-footer {
  padding: 1em 1.5em;
  border-top: 2px solid rgba(245, 73, 0, 0.4);
  background: rgba(23, 23, 23, 0.5);
  
  .power-weight-stats {
    margin-bottom: 1em;
    padding-bottom: 1em;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    
    .stats-container {
      display: grid;
      grid-template-columns: auto 1fr auto 1fr;
      gap: 0.75em;
      align-items: center;
    }
    
    .stat-row {
      display: contents;
      font-size: 0.875em;
      
      .stat-label-col {
        color: rgba(255, 255, 255, 0.6);
        text-align: right;
        padding-right: 0.5em;
        grid-column: 1;
      }
      
      .stat-value-col {
        color: rgba(255, 255, 255, 0.9);
        font-family: 'Courier New', monospace;
        text-align: right;
        white-space: nowrap;
        grid-column: 2;
      }
      
      .stat-arrow-col {
        display: flex;
        align-items: center;
        justify-content: center;
        color: rgba(245, 73, 0, 0.8);
        flex-shrink: 0;
        grid-column: 3;
        width: 24px;
        
        svg {
          width: 16px;
          height: 16px;
        }
      }
      
      .stat-value-col:last-of-type {
        grid-column: 4;
      }
    }
    
    .stat-row:nth-child(1) .stat-label-col { grid-row: 1; }
    .stat-row:nth-child(1) .stat-value-col:nth-of-type(1) { grid-row: 1; }
    .stat-row:nth-child(1) .stat-arrow-col { grid-row: 1; }
    .stat-row:nth-child(1) .stat-value-col:nth-of-type(2) { grid-row: 1; }
    
    .stat-row:nth-child(2) .stat-label-col { grid-row: 2; }
    .stat-row:nth-child(2) .stat-value-col:nth-of-type(1) { grid-row: 2; }
    .stat-row:nth-child(2) .stat-arrow-col { grid-row: 2; }
    .stat-row:nth-child(2) .stat-value-col:nth-of-type(2) { grid-row: 2; }
    
    .stat-row:nth-child(3) .stat-label-col { grid-row: 3; }
    .stat-row:nth-child(3) .stat-value-col:nth-of-type(1) { grid-row: 3; }
    .stat-row:nth-child(3) .stat-arrow-col { grid-row: 3; }
    .stat-row:nth-child(3) .stat-value-col:nth-of-type(2) { grid-row: 3; }
  }
  
  .stat-change {
    padding: 0.125em 0.5em;
    border-radius: 0.25em;
    font-size: 0.875em;
    font-weight: 600;
    font-family: 'Courier New', monospace;
    
    &.positive {
      background: rgba(0, 200, 0, 0.2);
      color: rgba(0, 255, 0, 0.9);
    }
    
    &.negative {
      background: rgba(200, 0, 0, 0.2);
      color: rgba(255, 100, 100, 0.9);
    }
  }
  
  .cart-total {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1em;
    color: rgba(255, 255, 255, 0.9);
    font-size: 1em;
    
    .total-amount {
      color: rgba(245, 73, 0, 1);
      font-weight: 600;
      font-size: 1.25em;
      font-family: 'Courier New', monospace;
    }
  }
  
  .cart-buttons {
    display: flex;
    gap: 0.5em;
  }
}

.btn {
  flex: 1;
  padding: 0.75em 1em;
  border-radius: 0.375em;
  font-size: 0.875em;
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

