<template>
  <div class="tree-node">
    <div class="cart-item" :style="{ paddingLeft: (level * 1.5) + 'em' }">
      <!-- Collapse/Expand button for nodes with children -->
      <button 
        v-if="hasChildren"
        class="collapse-button"
        @click="isCollapsed = !isCollapsed"
        :title="isCollapsed ? 'Expand' : 'Collapse'"
      >
        <svg 
          width="12" 
          height="12" 
          viewBox="0 0 24 24" 
          fill="none" 
          stroke="currentColor" 
          stroke-width="2"
          :class="{ rotated: isCollapsed }"
        >
          <polyline points="9 18 15 12 9 6"/>
        </svg>
      </button>
      <div v-else class="collapse-button-placeholder"></div>
      
      <button 
        v-if="node.canRemove !== false" 
        class="remove-button" 
        @click="$emit('remove', node.id)">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"/>
          <line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
      <div v-else class="remove-button-placeholder"></div>
      <div class="item-info">
        <div class="item-name">
          <span v-if="level > 0" class="tree-connector">├─ </span>
          {{ node.partNiceName || node.partName }}
          <span v-if="hasChildren && isCollapsed" class="children-count">
            ({{ childrenCount }})
          </span>
        </div>
        <div class="item-slot">{{ node.slotNiceName || node.slotName }}</div>
      </div>
      <div class="item-price">
        <span v-if="hasChildren && isCollapsed" class="total-price">
          ${{ childrenTotalCost.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}
        </span>
        <span v-else>
          ${{ (node.price || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}
        </span>
      </div>
    </div>
    <transition name="collapse">
      <div v-if="hasChildren && !isCollapsed" class="children-container">
        <PartsTreeItem
          v-for="child in node.children"
          :key="child.id"
          :node="child"
          :level="level + 1"
          @remove="$emit('remove', $event)"
        />
      </div>
    </transition>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue'

const props = defineProps({
  node: {
    type: Object,
    required: true
  },
  level: {
    type: Number,
    default: 0
  }
})

defineEmits(['remove'])

const isCollapsed = ref(false)

const hasChildren = computed(() => {
  return props.node.children && props.node.children.length > 0
})

const childrenCount = computed(() => {
  if (!hasChildren.value) return 0
  
  const countAllDescendants = (node) => {
    let count = 0
    if (node.children && node.children.length > 0) {
      for (const child of node.children) {
        count += 1 // Count the child itself
        count += countAllDescendants(child) // Recursively count its descendants
      }
    }
    return count
  }
  
  return countAllDescendants(props.node)
})

const childrenTotalCost = computed(() => {
  if (!hasChildren.value) return 0
  
  const calculateTotal = (node) => {
    let total = node.price || 0
    if (node.children && node.children.length > 0) {
      for (const child of node.children) {
        total += calculateTotal(child)
      }
    }
    return total
  }
  
  return calculateTotal(props.node)
})
</script>

<style scoped lang="scss">
.tree-node {
  display: flex;
  flex-direction: column;
}

.tree-connector {
  color: rgba(255, 255, 255, 0.4);
  margin-right: 0.25em;
  font-family: monospace;
}

.cart-item {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.75em 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  
  .collapse-button {
    background: transparent;
    border: none;
    color: rgba(255, 255, 255, 0.4);
    cursor: pointer;
    padding: 0.25em;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: color 0.2s, transform 0.2s;
    flex-shrink: 0;
    
    &:hover {
      color: rgba(245, 73, 0, 0.8);
    }
    
    svg {
      width: 12px;
      height: 12px;
      transition: transform 0.2s;
      
      &.rotated {
        transform: rotate(-90deg);
      }
    }
  }
  
  .collapse-button-placeholder {
    width: 20px;
    height: 20px;
    flex-shrink: 0;
  }
  
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
  
  .remove-button-placeholder {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    padding: 0.25em;
  }
  
  .item-info {
    flex: 1;
    min-width: 0;
    
    .item-name {
      color: rgba(255, 255, 255, 0.9);
      font-size: 0.875em;
      font-weight: 500;
      margin-bottom: 0.25em;
      display: flex;
      align-items: center;
      gap: 0.5em;
      
      .children-count {
        color: rgba(255, 255, 255, 0.5);
        font-size: 0.875em;
        font-weight: 400;
      }
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
    
    .total-price {
      color: rgba(245, 73, 0, 0.8);
      font-size: 0.8em;
    }
  }
}

.children-container {
  overflow: hidden;
}

.collapse-enter-active,
.collapse-leave-active {
  transition: max-height 0.3s ease, opacity 0.2s ease;
  overflow: hidden;
}

.collapse-enter-from {
  max-height: 0;
  opacity: 0;
}

.collapse-enter-to {
  max-height: 1000px;
  opacity: 1;
}

.collapse-leave-from {
  max-height: 1000px;
  opacity: 1;
}

.collapse-leave-to {
  max-height: 0;
  opacity: 0;
}
</style>

