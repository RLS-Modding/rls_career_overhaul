<template>
  <div class="ccm-tab-panel">
    <div class="ccm-grid2">
      <div class="ccm-field">
        <label>Starting Capital</label>
        <input v-bng-text-input
          v-model.number="capitalModel"
          type="number"
          step="500"
          min="0"
          class="ccm-input"
          @keyup.enter="emit('roundCapital')"
          @blur="emit('roundCapital')"
        />
      </div>
      <div class="ccm-field">
        <label>Win Condition</label>
        <template v-if="winConditionOptions && winConditionOptions.length > 0">
          <BngSelect v-model="winConditionModel" :options="winConditionOptions" :config="winConditionConfig" placeholder="Select win condition" />
        </template>
        <template v-else>
          <div class="ccm-hint">Loading win conditions…</div>
        </template>
      </div>
    </div>

    <div class="ccm-debt-section">
      <div class="ccm-section-title">Debt {{ loansRequired ? '(required)' : '(optional)' }}</div>
      <div class="ccm-grid3">
      <div class="ccm-field">
        <label>Amount{{ loansRequired ? ' *' : '' }}</label>
        <input v-bng-text-input
          v-model.number="loanAmountModel"
          type="number"
          step="1000"
          :min="loansRequired ? 10000 : 0"
          max="10000000"
          class="ccm-input"
          :class="{ 'ccm-required': loansRequired && !loanAmount }"
          @keyup.enter="emit('roundLoanAmount')"
          @blur="emit('roundLoanAmount')"
        />
      </div>
      <div class="ccm-field">
        <label>Interest (%){{ loansRequired ? ' *' : '' }}</label>
        <input v-bng-text-input v-model="interestModel" type="number" min="0" max="100" step="0.1" class="ccm-input" :class="{ 'ccm-required': loansRequired && !loanAmount }" />
      </div>
      <div class="ccm-field">
        <label>Payments{{ loansRequired ? ' *' : '' }}</label>
        <input v-bng-text-input v-model.number="loanPaymentsModel" type="number" :min="loansRequired ? 1 : 0" step="1" class="ccm-input" :class="{ 'ccm-required': loansRequired && !loanAmount }" />
        <div class="ccm-hint">Each payment <BngIcon class="cur" :type="icons.beamCurrency" />{{ perPaymentDisplay }}</div>
        <div class="ccm-hint">Paid off in about {{ paymentsMinutes }} min</div>
      </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { vBngTextInput } from "@/common/directives"
// Starting parameters: capital, win condition and the debt block. Every field is a writable computed over a
// prop, so v-model writes go out as update events and the parent's refs stay the only state.
import { computed } from 'vue'
import { BngIcon, BngSelect, icons } from '@/common/components/base'

const props = defineProps({
  startingCapital: { default: undefined },
  winCondition: { default: undefined },
  winConditionOptions: { type: Array, default: () => [] },
  loansRequired: { type: Boolean, default: false },
  loanAmount: { default: undefined },
  interestPercent: { default: undefined },
  loanPayments: { default: undefined },
  paymentsMinutes: { default: undefined },
  perPaymentDisplay: { default: undefined },
})
const emit = defineEmits([
  'update:startingCapital', 'update:winCondition', 'update:loanAmount', 'update:interestPercent', 'update:loanPayments',
  'roundCapital', 'roundLoanAmount',
])

const winConditionConfig = { value: opt => opt.value, label: opt => opt.label }

const capitalModel = computed({ get: () => props.startingCapital, set: value => emit('update:startingCapital', value) })
const winConditionModel = computed({ get: () => props.winCondition, set: value => emit('update:winCondition', value) })
const loanAmountModel = computed({ get: () => props.loanAmount, set: value => emit('update:loanAmount', value) })
const interestModel = computed({ get: () => props.interestPercent, set: value => emit('update:interestPercent', value) })
const loanPaymentsModel = computed({ get: () => props.loanPayments, set: value => emit('update:loanPayments', value) })
</script>

<style scoped lang="scss">
.ccm-grid3 {
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 0.75em;
}

.ccm-debt-section {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}

// An empty required debt field: a red edge on the field only, the panel stays neutral.
.ccm-input.ccm-required {
  border-color: rgba(252, 165, 165, 0.6);
}

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
