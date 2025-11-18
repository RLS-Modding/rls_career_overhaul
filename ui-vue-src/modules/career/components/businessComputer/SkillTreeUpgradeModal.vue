<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div v-if="show" class="modal-overlay" @click.self="handleCancel">
        <div class="modal-content" @click.stop>
          <h2>Confirm Upgrade</h2>
          <div class="upgrade-info">
            <div class="info-row">
              <span class="label">Upgrade:</span>
              <span class="value">{{ node.title }}</span>
            </div>
            <div class="info-row">
              <span class="label">Current Level:</span>
              <span class="value">{{ node.currentLevel }}/{{ node.maxLevel || '∞' }}</span>
            </div>
            <div class="info-row">
              <span class="label">New Level:</span>
              <span class="value">{{ (node.currentLevel || 0) + 1 }}/{{ node.maxLevel || '∞' }}</span>
            </div>
            <div class="info-row">
              <span class="label">Cost:</span>
              <span class="value cost">${{ formatCost(node.cost, node.currentLevel) }}</span>
            </div>
            <div v-if="node.description" class="info-row description">
              <span class="label">Effect:</span>
              <span class="value">{{ node.description }}</span>
            </div>
          </div>
          <div class="modal-buttons">
            <button class="btn btn-secondary" @click.stop="handleCancel" @mousedown.stop>Cancel</button>
            <button class="btn btn-primary" @click.stop="handleConfirm" @mousedown.stop>Confirm Purchase</button>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { computed } from "vue"
import { Teleport } from "vue"

const props = defineProps({
  node: Object,
  treeId: String,
  show: {
    type: Boolean,
    default: true
  }
})

const emit = defineEmits(['confirm', 'cancel'])

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

const handleConfirm = () => {
  emit('confirm')
}

const handleCancel = () => {
  emit('cancel')
}
</script>

<style scoped lang="scss">
.modal-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10000;
  backdrop-filter: blur(4px);
}

.modal-content {
  background: rgba(15, 15, 15, 0.95);
  border: 2px solid rgba(245, 73, 0, 0.6);
  border-radius: 0.5em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);

  h2 {
    margin: 0 0 1.5em 0;
    color: white;
    font-size: 1.5em;
    font-weight: 600;
  }
}

.upgrade-info {
  margin-bottom: 2em;
}

.info-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 1em;
  gap: 1em;

  .label {
    color: rgba(255, 255, 255, 0.6);
    font-size: 0.875em;
    flex-shrink: 0;
  }

  .value {
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.875em;
    text-align: right;
    flex: 1;

    &.cost {
      color: #4CAF50;
      font-weight: 600;
    }
  }

  &.description {
    flex-direction: column;
    align-items: flex-start;

    .value {
      text-align: left;
      margin-top: 0.25em;
    }
  }
}

.modal-buttons {
  display: flex;
  gap: 1em;
  justify-content: flex-end;
}

.btn {
  padding: 0.75em 1.5em;
  border: none;
  border-radius: 0.25em;
  font-size: 0.875em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;

  &.btn-secondary {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.9);

    &:hover {
      background: rgba(255, 255, 255, 0.15);
    }
  }

  &.btn-primary {
    background: #F54900;
    color: white;

    &:hover {
      background: #ff5a14;
      box-shadow: 0 0 10px rgba(245, 73, 0, 0.4);
    }
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s ease;

  .modal-content {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .modal-content {
    transform: scale(0.95);
    opacity: 0;
  }
}
</style>

