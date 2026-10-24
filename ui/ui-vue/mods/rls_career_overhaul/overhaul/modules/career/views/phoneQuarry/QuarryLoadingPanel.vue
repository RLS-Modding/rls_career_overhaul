<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="state-panel loading">
    <!-- Zone Stock Display -->
    <div class="zone-stock-section" v-if="zoneStock && zoneStock.materialStocks">
      <div class="zone-stock-header">Zone Stock</div>
      <div class="zone-stock-materials">
        <div
          v-for="(stock, matKey) in zoneStock.materialStocks"
          :key="matKey"
          class="zone-stock-material-item"
        >
          <div class="zone-stock-material-name">{{ stock.materialName || matKey }}</div>
          <div class="zone-stock-info">
            <div class="zone-stock-bar-container">
              <div
                class="zone-stock-bar"
                :class="getStockLevelClass(stock.current, stock.max)"
                :style="{ width: ((stock.current / stock.max) * 100) + '%' }"
              ></div>
            </div>
            <div class="zone-stock-text">
              <span>{{ stock.current }}</span>
              <span>/</span>
              <span>{{ stock.max }}</span>
              <span v-if="stock.regenRate > 0" class="zone-stock-regen">(+{{ stock.regenRate }}/hr)</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="payload-section compact" v-if="contract && contract.unitType !== 'item'">
      <div class="payload-header">
        <span class="payload-label">Payload</span>
        <span class="payload-value">{{ formatNumber(currentLoadMass) }} / {{ formatNumber(targetLoad) }} tons</span>
      </div>
      <div class="payload-bar-container">
        <div
          class="payload-bar"
          :class="{ full: loadPercent >= FULL_LOAD_PERCENT }"
          :style="{ width: loadPercent + '%' }"
        ></div>
      </div>
      <div class="payload-percent">{{ loadPercent.toFixed(0) }}%</div>
    </div>

    <!-- Marble Block Status -->
    <div class="blocks-section" v-if="materialType === 'marble' && marbleBlocks && marbleBlocks.length > 0">
      <div class="blocks-header">
        <span>Marble Blocks</span>
        <span v-if="anyMarbleDamaged" class="damage-warning">Damaged blocks won't count</span>
      </div>
      <div class="blocks-list">
        <div
          v-for="block in marbleBlocks"
          :key="block.index"
          class="block-item"
          :class="{ damaged: block.isDamaged, loaded: block.isLoaded }"
        >
          <span class="block-label">Block {{ block.index }}</span>
          <span class="block-status" :class="{ damaged: block.isDamaged }">
            {{ block.isDamaged ? 'DAMAGED' : 'OK' }}
          </span>
          <span class="block-loaded">
            {{ block.isLoaded ? 'Loaded' : 'Not loaded' }}
          </span>
        </div>
      </div>
    </div>

    <button
      v-if="truckStatus !== 'arriving' && truckStatus !== 'spawning'"
      class="action-button primary"
      @click="emit('sendTruck')"
    >
      Send Truck
    </button>

    <button
      v-if="zones.length > 1 && !isComplete"
      class="action-button swap-zone"
      @click="emit('swapZone')"
    >
      Switch Zone
    </button>

    <button class="action-button danger small" @click="emit('abandon')">
      Abandon Contract
    </button>
  </div>
</template>

<script setup>
// Loading state: zone stock, payload against the target, marble block status, and the truck and zone actions.
import { formatNumber, getStockLevelClass } from './quarryMath.js'

// The payload bar turns green from this percentage.
const FULL_LOAD_PERCENT = 80

defineProps({
  contract: { type: Object, default: null },
  zoneStock: { type: Object, default: null },
  currentLoadMass: { default: 0 },
  targetLoad: { default: 0 },
  loadPercent: { type: Number, required: true },
  materialType: { type: String, default: 'rocks' },
  marbleBlocks: { type: Array, default: () => [] },
  anyMarbleDamaged: { default: false },
  truckStatus: { type: String, default: 'none' },
  zones: { type: Array, required: true },
  isComplete: { default: false },
})
const emit = defineEmits(['sendTruck', 'swapZone', 'abandon'])
</script>

<style scoped lang="scss">
// Payload Section
.payload-section {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.75em;
  
  &.compact {
    padding: 0.5em 0.75em;
    margin-bottom: 0.4em;
  }
}

.payload-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 0.4em;
  
  .payload-section.compact & {
    margin-bottom: 0.3em;
  }
  
  .payload-label {
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.85em;
  }
  
  .payload-value {
    color: #fff;
    font-weight: 600;
    font-size: 0.85em;
  }
}

.payload-bar-container {
  height: 20px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  overflow: hidden;
}

.payload-bar {
  height: 100%;
  background: linear-gradient(90deg, #ff6600, #ff9933);
  border-radius: 10px;
  transition: width 0.3s ease;
  
  &.full {
    background: linear-gradient(90deg, #22c55e, #16a34a);
  }
}

.payload-percent {
  text-align: center;
  font-weight: 700;
  font-size: 1em;
  color: #fff;
  margin-top: 0.35em;
}

// Blocks Section
.blocks-section {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.5em 0.75em;
  margin-bottom: 0.5em;
}

.blocks-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.4em;
  font-size: 0.85em;
  color: rgba(255, 255, 255, 0.8);
  
  .damage-warning {
    color: #fbbf24;
    font-size: 0.75em;
  }
}

.blocks-list {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.block-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.35em 0.5em;
  background: rgba(255, 255, 255, 0.05);
  border-radius: 6px;
  font-size: 0.8em;
  
  &.damaged {
    background: rgba(248, 113, 113, 0.15);
  }
  
  .block-label {
    color: #fff;
    font-weight: 500;
  }
  
  .block-status {
    color: #4ade80;
    font-weight: 600;
    
    &.damaged {
      color: #f87171;
      animation: blink 1s ease-in-out infinite;
    }
  }
  
  .block-loaded {
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.9em;
  }
}

@keyframes blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}
// Zone Stock Section (in Loading state)
.zone-stock-section {
  background: rgba(30, 30, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  padding: 0.5em 0.75em;
  margin-bottom: 0.6em;
}

.zone-stock-header {
  font-size: 0.85em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.8);
  margin-bottom: 0.4em;
}

.zone-stock-materials {
  display: flex;
  flex-direction: column;
  gap: 0.4em;
}

.zone-stock-material-item {
  display: flex;
  flex-direction: column;
  gap: 0.25em;
}

.zone-stock-material-name {
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.8);
  font-weight: 500;
}

.zone-stock-info {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
}

.zone-stock-bar-container {
  height: 6px;
  background: rgba(255, 255, 255, 0.1);
  border-radius: 3px;
  overflow: hidden;
}

.zone-stock-bar {
  height: 100%;
  border-radius: 3px;
  transition: width 0.3s ease;
  
  &.low {
    background: #ef4444;
  }
  
  &.medium {
    background: #ff6600;
  }
  
  &.high {
    background: #22c55e;
  }
  
  &.empty {
    background: rgba(255, 255, 255, 0.2);
  }
}

.zone-stock-text {
  font-size: 0.8em;
  color: rgba(255, 255, 255, 0.7);
  display: flex;
  align-items: center;
  gap: 0.3em;
}

.zone-stock-regen {
  color: #ff6600;
  font-size: 0.9em;
}
</style>
