<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="state-panel">
    <template v-if="phase === 'return_to_quarry'">
      <div class="active-contract-info" v-if="contract">
        <div class="contract-name">{{ contract.name }}</div>
        <div class="contract-progress" :class="{ complete: isContractComplete }">
          <template v-if="contract.unitType === 'item'">
            {{ progress.deliveredItems || 0 }} / {{ contract.requiredItems || 0 }} {{ contract.units || 'items' }}
          </template>
          <template v-else>
            {{ formatNumber(progress.deliveredTons || 0) }} / {{ contract.requiredTons || 0 }} {{ contract.units || 'tons' }}
          </template>
          <span v-if="isContractComplete" class="complete-badge">COMPLETE!</span>
        </div>
        <div class="payout-info">
          Payout: ${{ formatNumber(contract.totalPayout || 0) }}
        </div>
      </div>

      <div class="status-section">
        <div class="status-icon pulsing">↩️</div>
        <div class="status-title">Return to Starter Zone</div>
        <div class="status-message">
          {{ isContractComplete ? 'Contract complete! Return to starter zone to finalize and get paid.' : 'Return to starter zone to continue.' }}
        </div>
      </div>

      <button class="action-button danger" @click="emit('abandon')">
        Abandon Contract
      </button>
    </template>

    <template v-else>
      <div class="active-contract-info" v-if="contract">
        <div class="contract-name">{{ contract.name }}</div>
        <div class="contract-progress" :class="{ complete: isContractComplete }">
          <template v-if="contract.unitType === 'item'">
            {{ progress.deliveredItems || 0 }} / {{ contract.requiredItems || 0 }} {{ contract.units || 'items' }}
            ({{ progressPercent.toFixed(0) }}%)
          </template>
          <template v-else>
            {{ formatNumber(progress.deliveredTons || 0) }} / {{ contract.requiredTons || 0 }} {{ contract.units || 'tons' }}
            ({{ progressPercent.toFixed(0) }}%)
          </template>
        </div>
        <div class="payout-info complete">
          Payout: ${{ formatNumber(contract.totalPayout || 0) }}
        </div>
      </div>

      <div class="status-section" v-if="isComplete">
        <div class="status-icon">✅</div>
        <div class="status-title complete">Contract Complete!</div>
        <div class="status-message">Finalize to collect your payment.</div>
      </div>

      <div class="status-section" v-else>
        <div class="status-icon">📍</div>
        <div class="status-title">At Starter Zone</div>
        <div class="status-message">Continue your contract or swap zones.</div>
      </div>

      <div class="actions-section">
        <button v-if="isComplete" class="action-button success" @click="emit('finalize')">
          Finalize & Get Paid
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
  </div>
</template>

<script setup>
// Return to the starter zone (return_to_quarry) and the decision at the starter zone (at_quarry_decide).
// Finalize pays out only once the contract is complete.
import { formatNumber } from './quarryMath.js'

defineProps({
  phase: { type: String, required: true },
  contract: { type: Object, default: null },
  progress: { type: Object, required: true },
  progressPercent: { type: Number, required: true },
  isContractComplete: { default: false },
  isComplete: { default: false },
  zones: { type: Array, required: true },
})
const emit = defineEmits(['finalize', 'swapZone', 'abandon'])
</script>

<style scoped lang="scss">
// Actions Section
.actions-section {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}
</style>
