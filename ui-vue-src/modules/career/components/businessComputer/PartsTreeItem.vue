<template>
  <div class="tree-node">
    <div class="cart-item" :style="{ paddingLeft: (level * 1.5) + 'em' }">
      <button class="remove-button" @click="$emit('remove', node.id)">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <line x1="18" y1="6" x2="6" y2="18"/>
          <line x1="6" y1="6" x2="18" y2="18"/>
        </svg>
      </button>
      <div class="item-info">
        <div class="item-name">
          <span v-if="level > 0" class="tree-connector">├─ </span>
          {{ node.partNiceName || node.partName }}
        </div>
        <div class="item-slot">{{ node.slotNiceName || node.slotName }}</div>
      </div>
      <div class="item-price">${{ (node.price || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }}</div>
    </div>
    <template v-if="node.children && node.children.length > 0">
      <PartsTreeItem
        v-for="child in node.children"
        :key="child.id"
        :node="child"
        :level="level + 1"
        @remove="$emit('remove', $event)"
      />
    </template>
  </div>
</template>

<script setup>
defineProps({
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
</style>

