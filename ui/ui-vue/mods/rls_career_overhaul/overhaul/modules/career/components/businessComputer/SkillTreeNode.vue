<template>
  <div
    :class="['skill-node', {
      'locked': !node.unlocked,
      'affordable': node.affordable && node.unlocked && !node.maxed,
      'maxed': node.maxed,
      'purchased': node.currentLevel > 0,
      'comming-soon': node.commingSoon
    }]"
    :style="{
      left: (node.position?.x || 0) + 'px',
      top: (node.position?.y || 0) + 'px'
    }"
    @click.stop="handleClick"
    @mousedown.stop
    bng-nav-item
    :bng-no-nav="node.commingSoon ? 'true' : null"
  >
    <div v-if="node.commingSoon" class="coming-soon-content">
      <span class="coming-soon-text">Coming soon</span>
    </div>
    <template v-else>
      <div class="node-header">
        <h3 class="node-title">{{ node.title }}</h3>
        <span v-if="node.maxLevel > 1" class="node-level">
          {{ node.currentLevel }}/{{ node.maxLevel }}
        </span>
      </div>
      <p v-if="node.description" class="node-description">{{ node.description }}</p>
      <div class="node-costs">
        <div class="node-cost" v-if="formatCost(node.cost, node.currentLevel) !== '0'">
          <span class="cost-label">Cost</span>
          <span class="cost-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatCost(node.cost, node.currentLevel) }}</span>
        </div>
        <div class="node-cost" v-if="node.xpCost !== undefined">
          <span class="cost-label">XP</span>
          <span class="cost-value xp">{{ formatCost(node.xpCost, node.currentLevel) }}</span>
        </div>
      </div>
      <div v-if="!node.unlocked" class="node-lock">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
          <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
        </svg>
        <span>Locked</span>
      </div>
    </template>
  </div>
</template>

<script setup>
import { BngIcon, icons } from "@/common/components/base"

const props = defineProps({
  node: Object,
  treeId: String
})

const emit = defineEmits(['upgrade'])

const formatCost = (cost, currentLevel) => {
  if (typeof cost === 'number') {
    return cost.toLocaleString()
  }
  if (cost !== null && typeof cost === 'object') {
    const base = cost.base ?? cost[1] ?? 0
    const increment = cost.increment ?? cost[2] ?? 0
    const total = base + (increment * (currentLevel ?? 0))
    return total.toLocaleString()
  }
  return '0'
}

const handleClick = () => {
  if (props.node.commingSoon) {
    return
  }
  emit('upgrade', props.node)
}
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Skill tree node, house style: near-black panel with a hairline ring; bought nodes get accent-soft
   titles and a soft warm glow, locked nodes are dimmed, cost in money gold.
   Width stays in px: node positions and spacing in BusinessSkillTreeTab are canvas (px) units. */

.skill-node {
  // controller focus: the house ring (the node keeps its own selected/affordable looks)
  position: absolute;
  width: 200px;
  padding: 0.9em 1em 0.85em;
  display: grid;
  gap: 0.5em;
  border-radius: var(--radius-panel, 0.5em);
  background: rgba(20, 20, 22, 0.96);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.1);
  color: #fff;
  cursor: pointer;
  transition: transform 0.12s ease, opacity 0.12s ease;
  z-index: 10;

  &:hover {
    transform: translateY(-2px);
    background: rgba(30, 30, 33, 0.98);
  }

  &.affordable {
    box-shadow: 0 0 0 1px rgba(255, 178, 122, 0.4);
  }

  &.purchased {
    box-shadow: 0 0 0 1px rgba(255, 178, 122, 0.35), 0 0 18px rgba(255, 102, 0, 0.16);

    .node-title {
      color: var(--accent-soft, #ffb27a);
    }
  }

  &.maxed {
    background: rgba(28, 20, 15, 0.97);
    box-shadow: 0 0 0 1px rgba(255, 178, 122, 0.45), 0 0 22px rgba(255, 102, 0, 0.2);
  }

  &.locked {
    opacity: 0.5;

    &:hover {
      opacity: 0.7;
    }
  }

  &.comming-soon {
    opacity: 0.4;
    cursor: default;
    background: rgba(20, 20, 22, 0.7);
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06);

    &:hover {
      transform: none;
      opacity: 0.4;
    }
  }
}

.skill-node { @include house-focus; }

.coming-soon-content {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  min-height: 6em;
}

.coming-soon-text {
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  text-align: center;
}

.node-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 0.5em;
}

.node-title {
  margin: 0;
  min-width: 0;
  color: #fff;
  font-size: 1.05em;
  font-weight: 800;
  line-height: 1.2;
  overflow-wrap: anywhere;
}

.node-level {
  flex: 0 0 auto;
  margin-top: 0.1em;
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.82em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.node-description {
  margin: 0;
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1.4;
}

.node-costs {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em 1.2em;
  padding-top: 0.55em;
  border-top: 1px solid var(--line, rgba(255, 255, 255, 0.1));
}

.node-cost {
  display: grid;
  gap: 0.1em;

  .cost-label {
    font-size: 0.68em;
    font-weight: 700;
    letter-spacing: 0.09em;
    text-transform: uppercase;
    color: var(--faint, rgba(255, 255, 255, 0.55));
  }

  .cost-value {
    color: var(--money, #fde68a);
    font-variant-numeric: tabular-nums;
    font-weight: 700;
    font-size: 0.95em;

    &.xp {
      color: #fff;
    }
  }
}

.node-lock {
  display: flex;
  align-items: center;
  gap: 0.4em;
  color: var(--faint, rgba(255, 255, 255, 0.55));
  font-size: 0.82em;
  font-weight: 700;

  svg {
    flex-shrink: 0;
    width: 1em;
    height: 1em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
    transform: translateY(-0.05em);
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
