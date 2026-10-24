<template>
  <div class="deposit-modal-overlay" @pointerdown.self="close">
    <div class="deposit-modal">
      <div class="modal-header">
        <h3 class="modal-title">Deposit</h3>
        <button class="close-btn" type="button" aria-label="Cancel" bng-scoped-nav-autofocus @click="close">×</button>
      </div>
      <form @submit.prevent="handleSubmit" class="form">
        <div class="form-group">
          <label class="form-label">Amount</label>
          <div class="input-with-prefix">
            <span class="input-prefix">$</span>
            <input
              v-model.number="amount"
              v-bng-on-ui-nav:focus_l,focus_r,tab_l,tab_r,context,ok.focusRequired="amountNav"
              type="number"
              step="0.01"
              min="0.01"
              :max="walletBalance"
              placeholder="0.00"
              class="form-input"
              @pointerdown="typing.onFocus" @keydown="typing.onFocus" @blur="typing.onBlur"
              required
            />
          </div>
          <p class="form-hint">Available: ${{ formatCurrency(walletBalance) }}</p>
        </div>

        <button
          type="submit"
          class="submit-btn"
          :disabled="!amount || amount <= 0 || amount > walletBalance || processing"
        >
          {{ processing ? 'Depositing...' : `Deposit $${formatCurrency(amount || 0)}` }}
        </button>
      </form>
    </div>
  </div>
</template>

<script setup>

import { vBngOnUiNav } from "@/common/directives"
import { useCefTyping } from "../../composables/useCefTyping.js"
import { amountValue } from "../../utils/amountValue.js"
const typing = useCefTyping()

import { reportUiFailure } from "../../utils/safeLua.js"

import { ref, onMounted } from 'vue'
import { lua } from '@/bridge'

const props = defineProps({
  accountId: {
    type: String,
    required: true
  }
})

const emit = defineEmits(['return'])

const amount = ref('')
const walletBalance = ref(0)
const processing = ref(false)

const formatCurrency = (val) => {
  const num = typeof val === 'string' ? parseFloat(val) : (val || 0)
  return num.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const close = () => {
  emit('return', false)
  amount.value = 0
}

const handleSubmit = async () => {
  if (!amount.value || amount.value <= 0 || amount.value > walletBalance.value || processing.value) return

  processing.value = true
  try {
    const success = await lua.overhaul_career_economy_bank.deposit(
      props.accountId,
      parseFloat(amount.value)
    )
    if (success) {
      emit('return', true)
    }
  } catch (e) {
    reportUiFailure(e, "Failed to deposit:")
  } finally {
    processing.value = false
  }
}

onMounted(async () => {
    try {
      walletBalance.value = await lua.overhaul_career_economy_playerAttributes.getAttributeValue('money') || 0
    } catch (e) {
      reportUiFailure(e, "Failed to load wallet balance:")
    }
})

const amountNav = event => {
  event?.stopPropagation()
  const { name, value } = event?.detail || {}
  if (!value || name === "ok") return
  const delta = { focus_l: -0.01, focus_r: 0.01, tab_l: -100, tab_r: 100 }[name] || 0
  const next = name === "context" ? walletBalance.value : (Number(amount.value) || 0) + delta
  amount.value = amountValue(next, { min: 0, max: walletBalance.value, step: 0.01 })
}

</script>
<style scoped lang="scss">
.deposit-modal-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.deposit-modal {
  background: white;
  border-radius: 16px;
  padding: 20px;
  width: 90%;
  max-width: 400px;
  box-shadow: 0 12px 24px rgba(0, 0, 0, 0.2);
}

.modal-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
}

.modal-title {
  font-size: 1.3rem;
  font-weight: 800;
  margin: 0;
  color: #1e293b;
}

.close-btn {
  background: none;
  border: none;
  font-size: 2rem;
  color: #64748b;
  cursor: pointer;
  padding: 0;
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  line-height: 1;
  transition: color 0.2s ease;

  &:hover {
    color: #1e293b;
  }
}

.form {
  display: flex;
  flex-direction: column;
}

.form-group {
  margin-bottom: 16px;
}

.form-label {
  display: block;
  font-weight: 600;
  margin-bottom: 8px;
  color: #1e293b;
  line-height: 1.2;
}

.form-input {
  width: 100%;
  padding: 10px;
  border: 1px solid #cbd5e1;
  border-radius: 10px;
  font-size: 1rem;
  background: white;
  color: #1e293b;
  box-sizing: border-box;

  &:focus {
    outline: none;
    border-color: #3b82f6;
    box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
  }

  &::placeholder {
    color: #94a3b8;
  }
}

.input-with-prefix {
  position: relative;
}

.input-prefix {
  position: absolute;
  left: 12px;
  top: 50%;
  transform: translateY(-50%);
  color: #64748b;
  font-weight: 600;
}

.input-with-prefix .form-input {
  padding-left: 32px;
}

.form-hint {
  font-size: 0.85rem;
  color: #64748b;
  margin-top: 4px;
  line-height: 1.2;
}

.submit-btn {
  width: 100%;
  padding: 12px;
  background: #10b981;
  color: white;
  border: none;
  border-radius: 10px;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover:not(:disabled) {
    background: #059669;
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}
</style>
