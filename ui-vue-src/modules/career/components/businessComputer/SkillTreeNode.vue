<template>
  <div
    :class="['skill-node', {
      'locked': !node.unlocked,
      'affordable': node.affordable && node.unlocked && !node.maxed,
      'maxed': node.maxed,
      'purchased': node.currentLevel > 0
    }]"
    :style="{
      left: (node.position?.x || 0) + 'px',
      top: (node.position?.y || 0) + 'px'
    }"
    @click.stop="handleClick"
    @mousedown.stop
  >
    <div class="node-header">
      <h3 class="node-title">{{ node.title }}</h3>
      <div v-if="node.maxLevel > 1" class="node-level">
        {{ node.currentLevel }}/{{ node.maxLevel }}
      </div>
    </div>
    <p v-if="node.description" class="node-description">{{ node.description }}</p>
    <div class="node-costs">
      <div class="node-cost" v-if="formatCost(node.cost, node.currentLevel) !== '0'">
        <span class="cost-label">Cost:</span>
        <span class="cost-value">${{ formatCost(node.cost, node.currentLevel) }}</span>
      </div>
      <div class="node-cost" v-if="node.xpCost !== undefined">
        <span class="cost-label">XP:</span>
        <span class="cost-value xp">{{ formatCost(node.xpCost, node.currentLevel) }}</span>
      </div>
    </div>
    <div v-if="!node.unlocked" class="node-lock">
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
        <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
      </svg>
      <span>Locked</span>
    </div>
  </div>
</template>

<script setup>

const props = defineProps({
  node: Object,
  treeId: String
})

const emit = defineEmits(['upgrade'])

const formatCost = (cost, currentLevel) => {
  if (typeof cost === 'number') {
    return cost.toLocaleString()
  }
  if (typeof cost === 'object') {
    const base = cost.base || cost[1] || 0
    const increment = cost.increment || cost[2] || 0
    const total = base + (increment * (currentLevel || 0))
    return total.toLocaleString()
  }
  return '0'
}

const handleClick = () => {
  emit('upgrade', props.node)
}
</script>

<style scoped lang="scss">
.skill-node {
  position: absolute;
  width: 200px;
  padding: 1rem;
  background: rgba(26, 26, 26, 0.9);
  border: 2px solid rgba(255, 255, 255, 0.2);
  border-radius: 0.5rem;
  cursor: pointer;
  transition: all 0.2s;
  z-index: 10;

  &:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }

  &.locked {
    opacity: 0.6;
    cursor: pointer;
    border-color: rgba(255, 255, 255, 0.1);

    &:hover {
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
      opacity: 0.8;
    }
  }

  &.affordable {
    border-color: #F54900;
    box-shadow: 0 0 10px rgba(245, 73, 0, 0.3);

    &:hover {
      border-color: #ff5a14;
      box-shadow: 0 0 15px rgba(245, 73, 0, 0.5);
    }
  }

  &.maxed {
    border-color: rgba(245, 73, 0, 0.8);
    background: rgba(35, 12, 0, 0.98);
  }

  &.purchased {
    border-color: rgba(245, 73, 0, 0.6);
  }
}

.node-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.5rem;
}

.node-title {
  margin: 0;
  color: #F54900;
  font-size: 1rem;
  font-weight: 600;
}

.node-level {
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.875rem;
}

.node-description {
  margin: 0.5rem 0;
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.875rem;
  line-height: 1.4;
}

.node-costs {
  margin-top: 0.75rem;
  padding-top: 0.75rem;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.node-cost {
  display: flex;
  justify-content: space-between;
  align-items: center;

  .cost-label {
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.875rem;
  }

  .cost-value {
    color: #4CAF50;
    font-weight: 600;
    font-size: 0.875rem;
    
    &.xp {
      color: #2196F3;
    }
  }
}

.node-lock {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-top: 0.75rem;
  padding: 0.5rem;
  background: rgba(255, 0, 0, 0.1);
  border-radius: 0.25rem;
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.875rem;

  svg {
    flex-shrink: 0;
  }
}
</style>

