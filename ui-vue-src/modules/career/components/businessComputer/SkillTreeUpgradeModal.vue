<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div v-if="show" class="modal-overlay" @click.self="handleCancel">
        <div class="modal-content" @click.stop ref="modalContentRef">
          <div class="modal-title">{{ modalTitle }}</div>
          <div class="upgrade-info">
            <div class="info-row cost-row" v-if="formatCost(node.cost, node.currentLevel) !== '0'">
              <span class="value cost" :class="{ 'unaffordable': !affordableMoney }">
                ${{ formatCost(node.cost, node.currentLevel) }}
              </span>
            </div>
            <div class="info-row cost-row" v-if="node.xpCost !== undefined && formatCost(node.xpCost, node.currentLevel) !== '0'">
              <span class="value cost xp" :class="{ 'unaffordable': !affordableXP }">
                {{ formatCost(node.xpCost, node.currentLevel) }} XP
              </span>
            </div>
            
            <div v-if="node.detailedDescription || node.description" class="info-row description-box">
              <div class="value" v-html="descriptionHtml"></div>
            </div>

            <div v-if="hasMultipleLevels" class="info-row stats-row">
              <div class="stat-item">
                <span class="label">Current Level</span>
                <span class="value">{{ node.currentLevel || 0 }}/{{ displayMaxLevel }}</span>
              </div>
              <div class="stat-item" v-if="!node.maxed">
                <span class="label">New Level</span>
                <span class="value highlight">{{ (node.currentLevel || 0) + 1 }}/{{ displayMaxLevel }}</span>
              </div>
            </div>

            <div v-if="lockReason" class="info-row locked-reason">
              <span class="label">Locked:</span>
              <span class="value">{{ lockReason }}</span>
            </div>
          </div>
          <div class="modal-buttons">
            <button class="btn btn-secondary" @click.stop="handleCancel" @mousedown.stop data-focusable>Close</button>
            <button 
              class="btn btn-primary" 
              :disabled="!canPurchase"
              @click.stop="handleConfirm" 
              @mousedown.stop
              data-focusable
            >
              {{ buttonText }}
            </button>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { computed, ref, watch, nextTick, inject, onMounted, onUnmounted } from "vue"
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

const controllerNav = inject('controllerNav', null)
const modalContentRef = ref(null)

const pushModalToController = () => {
  if (!controllerNav || !props.show) return
  nextTick(() => {
    if (modalContentRef.value) {
      controllerNav.pushModal(modalContentRef.value, handleCancel)
    }
  })
}

onMounted(() => {
  pushModalToController()
})

onUnmounted(() => {
  if (controllerNav && modalContentRef.value) {
    controllerNav.removeModal(modalContentRef.value)
  }
})

watch(() => props.show, (isOpen) => {
  if (isOpen) {
    pushModalToController()
  }
})

const modalTitle = computed(() => {
  if (props.node.maxed) return 'Upgrade Maxed'
  if (!props.node.unlocked) return 'Upgrade Locked'
  return `Confirm '${props.node.title}' Upgrade`
})

const hasMultipleLevels = computed(() => {
  const maxLevel = props.node.maxLevel
  if (maxLevel == null) return true
  const numericLevel = Number(maxLevel)
  if (Number.isNaN(numericLevel)) return true
  return numericLevel > 1
})

const displayMaxLevel = computed(() => {
  return props.node.maxLevel ?? '∞'
})

const affordableMoney = computed(() => {
  if (typeof props.node.affordableMoney === 'boolean') return props.node.affordableMoney
  return !!props.node.affordable
})

const affordableXP = computed(() => {
  if (typeof props.node.affordableXP === 'boolean') return props.node.affordableXP
  return !!props.node.affordable
})

const canPurchase = computed(() => {
  return props.node.unlocked && !props.node.maxed && affordableMoney.value && affordableXP.value
})

const buttonText = computed(() => {
  if (props.node.maxed) return 'Maxed Out'
  if (!props.node.unlocked) return 'Locked'
  if (!affordableMoney.value && !affordableXP.value) return 'Not Enough Money or XP'
  if (!affordableMoney.value) return 'Not Enough Money'
  if (!affordableXP.value) return 'Not Enough XP'
  return 'Confirm Purchase'
})

const lockReason = computed(() => {
  if (props.node.unlocked) return null
  
  if (props.node.prerequisites && props.node.prerequisites.length > 0) {
    const reasons = props.node.prerequisites.map(req => {
      if (req.type === 'totalUpgrades') {
        return `Requires ${req.min} Total Upgrades in this skill tree`
      }
      return 'Prerequisites not met'
    })
    return reasons.join(', ')
  }
  
  // If dependencies are missing (logic typically handled by unlocked flag, but good to be safe)
  if (props.node.dependencies && props.node.dependencies.length > 0) {
     return "Requires previous upgrades"
  }

  return "Locked"
})

const escapeHtml = (str) => {
  if (!str) return ''
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

const renderMarkdown = (text) => {
  if (!text) return ''

  const lines = text.split(/\r?\n/)
  let html = ''
  let inList = false

  const flushList = () => {
    if (inList) {
      html += '</ul>'
      inList = false
    }
  }

  for (const rawLine of lines) {
    let line = rawLine.trim()

    if (!line) {
      flushList()
      continue
    }

    if (line.startsWith('### ')) {
      flushList()
      html += `<h3>${escapeHtml(line.slice(4))}</h3>`
      continue
    }

    if (line.startsWith('## ')) {
      flushList()
      html += `<h2>${escapeHtml(line.slice(3))}</h2>`
      continue
    }

    if (line.startsWith('# ')) {
      flushList()
      html += `<h1>${escapeHtml(line.slice(2))}</h1>`
      continue
    }

    if (line.startsWith('- ')) {
      if (!inList) {
        html += '<ul>'
        inList = true
      }
      html += `<li>${escapeHtml(line.slice(2))}</li>`
      continue
    }

    flushList()

    let escaped = escapeHtml(line)
    escaped = escaped
      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
      .replace(/\*(.+?)\*/g, '<em>$1</em>')

    html += `<p>${escaped}</p>`
  }

  flushList()

  return html
}

const descriptionHtml = computed(() => {
  const text = props.node.detailedDescription || props.node.description || ''
  return renderMarkdown(text)
})

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
  border-radius: 0.9em;
  padding: 2em;
  max-width: 30em;
  width: 90%;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
}

.modal-title {
  margin: 0 0 0.5em 0;
  color: white;
  font-size: 1.5em;
  font-weight: 600;
}

.upgrade-info {
  .info-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 0.75em;
    gap: 1em;
    padding: 0.5em 0;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);

    &:last-child {
      border-bottom: none;
    }

    .label {
      color: rgba(255, 255, 255, 0.6);
      font-size: 0.9em;
      flex-shrink: 0;
    }

    .value {
      color: rgba(255, 255, 255, 0.9);
      font-size: 1em;
      text-align: right;
      flex: 1;
      font-weight: 500;

      &.highlight {
        color: #F54900;
      }

      &.cost {
        color: #4CAF50;
        font-weight: 600;
        font-size: 1.1em;
        
        &.unaffordable {
          color: #f44336;
        }

        &.xp {
          color: #2196F3;
          
          &.unaffordable {
            color: #f44336;
          }
        }
      }
    }
  }

  .cost-row {
    justify-content: center;

    .value.cost {
      text-align: center;
      font-size: 2.5em;
      letter-spacing: 0.03em;
    }
  }

  .stats-row {
    display: flex;
    justify-content: space-between;
    background: rgba(255, 255, 255, 0.05);
    padding: 0.75em;
    border-radius: 0.5em;
    border: none;
    
    .stat-item {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 0.25em;
      
      .label {
        font-size: 0.75em;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }
      
      .value {
        font-size: 1.25em;
        text-align: center;
      }
    }
  }

  .locked-reason {
    background: rgba(244, 67, 54, 0.1);
    border: 1px solid rgba(244, 67, 54, 0.3);
    padding: 0.75em;
    border-radius: 0.5em;
    align-items: flex-start;
    
    .label {
      color: #ff8a80;
    }
    
    .value {
      color: #ffcdd2;
      text-align: right;
    }
  }

  .description-box {
    flex-direction: column;
    align-items: flex-start;
    background: rgba(0, 0, 0, 0.2);
    padding: 0.75em 0.85em;
    border-radius: 0.5em;
    border: none;
    margin-top: 0.65em;

    .label {
      color: #F54900;
      font-size: 0.8em;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 0.2em;
    }

    .value {
      text-align: left;
      margin: 0;
      line-height: 1.5;
      color: rgba(255, 255, 255, 0.8);
      font-size: 0.95em;

      h1,
      h2,
      h3 {
        margin: 0 0 0.5em 0;
        font-size: 1em;
        font-weight: 600;
        color: rgba(255, 255, 255, 0.95);
      }

      p {
        margin: 0.25em 0;
      }

      ul {
        margin: 0.25em 0 0.25em 1.2em;
        padding: 0;
        list-style-type: disc;
      }

      li {
        margin: 0.15em 0;
      }
    }
  }
}

.modal-buttons {
  display: flex;
  gap: 1em;
  justify-content: flex-end;
  margin-top: 2em;
}

.btn {
  padding: 0.75em 1.5em;
  border: none;
  border-radius: 0.25em;
  font-size: 0.9em;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s;
  text-transform: uppercase;
  letter-spacing: 0.05em;

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    filter: grayscale(0.5);
  }

  &.btn-secondary {
    background: rgba(255, 255, 255, 0.1);
    color: rgba(255, 255, 255, 0.9);

    &:hover:not(:disabled) {
      background: rgba(255, 255, 255, 0.15);
    }
  }

  &.btn-primary {
    background: #F54900;
    color: white;

    &:hover:not(:disabled) {
      background: #ff5a14;
      box-shadow: 0 0 15px rgba(245, 73, 0, 0.4);
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

