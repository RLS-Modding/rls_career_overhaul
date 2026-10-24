<template>
  <Teleport to="body">
    <transition name="modal-fade">
      <div v-if="show" class="rls-house modal-overlay" @click.self="handleCancel">
        <div
          class="modal modal-content"
          v-bng-scoped-nav="modalScope" v-bc-modal-focus
          v-bng-on-ui-nav:back,menu="handleCancel"
          @click.stop>
          <div class="modal-head">
            <span class="caption">{{ modalCaption }}</span>
            <h3>{{ node.title }}</h3>
          </div>

          <div class="facts upgrade-facts">
            <div class="fact money" :class="{ bad: !affordableMoney }" v-if="formatCost(node.cost, node.currentLevel) !== '0'">
              <span class="fact-key">Cost</span>
              <span class="fact-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCost(node.cost, node.currentLevel) }}</span>
            </div>
            <div class="fact" :class="{ bad: !affordableXP }" v-if="node.xpCost !== undefined && formatCost(node.xpCost, node.currentLevel) !== '0'">
              <span class="fact-key">XP</span>
              <span class="fact-value">{{ formatCost(node.xpCost, node.currentLevel) }}</span>
            </div>
            <div class="fact" v-if="hasMultipleLevels">
              <span class="fact-key">Level</span>
              <span class="fact-value">
                {{ node.currentLevel || 0 }}/{{ displayMaxLevel }}<template v-if="!node.maxed"><span class="level-arrow" aria-hidden="true">&rarr;</span><span class="level-next">{{ (node.currentLevel || 0) + 1 }}</span></template>
              </span>
            </div>
          </div>

          <div v-if="node.detailedDescription || node.description" class="description-box" v-html="descriptionHtml"></div>

          <p v-if="lockReason" class="notice locked-reason">{{ lockReason }}</p>

          <div class="actions modal-buttons">
            <HouseButton variant="quiet" @click.stop="handleCancel" @mousedown.stop>Cancel</HouseButton>
            <HouseButton
              variant="primary"
              :disabled="!canPurchase"
              bng-scoped-nav-autofocus
              @click.stop="handleConfirm"
              @mousedown.stop
            >
              {{ buttonText }}
            </HouseButton>
          </div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { computed } from "vue"
import { Teleport } from "vue"
import { HouseButton } from "../house/index.js"
import { BngIcon, icons } from "@/common/components/base"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { bcModalScope, vBcModalFocus } from "./bcModalNav"

const props = defineProps({
  node: Object,
  treeId: String,
  show: {
    type: Boolean,
    default: true
  }
})

const emit = defineEmits(['confirm', 'cancel'])

// own controller scope while open; opens on the purchase button (Cancel when it is disabled), B cancels
const modalScope = bcModalScope("skill-upgrade")

// caption above the node name (the name itself is the modal title)
const modalCaption = computed(() => {
  if (props.node.maxed) return 'Upgrade maxed'
  if (!props.node.unlocked) return 'Upgrade locked'
  return 'Upgrade'
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
  return 'Upgrade'
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
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Upgrade confirm, house .modal: caption + node name, cost / XP / level as facts (red only when
   short), the description, quiet Cancel and the primary Upgrade. Teleported to body, so the overlay
   carries .rls-house and the shell's em scale itself. */

.modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

.modal-content {
  width: min(28em, 92vw);
  max-height: 86vh;
  overflow: auto;
  font-variant-numeric: tabular-nums;
}

.modal-head {
  display: grid;
  gap: 0.2em;

  h3 {
    font-size: 1.3em;
    line-height: 1.2;
    overflow-wrap: anywhere;
  }
}

.upgrade-facts {
  .fact-value {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
  }
}

.level-arrow {
  margin: 0 0.3em;
  color: var(--faint);
}

.level-next {
  color: var(--accent-soft);
}

.description-box {
  padding: 0.7em 0.8em 0.6em;
  border-radius: var(--radius-tile);
  background: var(--panel);
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.45;

  :deep(h1),
  :deep(h2),
  :deep(h3) {
    margin: 0 0 0.4em;
    font-size: 1em;
    font-weight: 800;
    color: #fff;
  }

  :deep(p) {
    margin: 0.25em 0;
    color: inherit;
    font-size: inherit;
  }

  :deep(ul) {
    margin: 0.25em 0 0.25em 1.2em;
    padding: 0;
    list-style-type: disc;
  }

  :deep(li) {
    margin: 0.15em 0;
  }

  :deep(strong) {
    color: #fff;
  }
}

.modal-buttons {
  margin-top: var(--space-1);

  > :deep(.house-button) {
    min-width: 6.5em;
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.18s ease;

  .modal-content {
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
}

.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;

  .modal-content {
    transform: scale(0.96);
    opacity: 0;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
