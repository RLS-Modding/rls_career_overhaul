<template>
  <div class="transfer-modal-overlay" @pointerdown.self="closeModal">
    <div class="transfer-modal">
      <div class="modal-header">
        <h3 class="modal-title">Transfer</h3>
        <button class="close-btn" type="button" aria-label="Cancel" bng-scoped-nav-autofocus @click.stop="closeModal">×</button>
      </div>
      <form @submit.prevent="handleSubmit" class="form">
        <div class="form-group">
          <label class="form-label">From Account</label>
          <div ref="fromAnchor" class="dropdown-anchor">
            <button class="dropdown-trigger" type="button" @click.stop="openFromMenu" @mousedown.stop>
              <span class="dropdown-label">{{ fromAccount ? `${fromAccount.name} - $${formatCurrency(fromAccount.balance)}` : 'Select account' }}</span>
              <span class="dropdown-caret">▾</span>
            </button>
          </div>
        </div>

        <div class="transfer-arrow">↓</div>

        <div class="form-group">
          <label class="form-label">To Account</label>
          <div ref="toAnchor" class="dropdown-anchor">
            <button class="dropdown-trigger" type="button" @click.stop="openToMenu" @mousedown.stop>
              <span class="dropdown-label">{{ toAccount ? `${toAccount.name} - $${formatCurrency(toAccount.balance)}` : 'Select account' }}</span>
              <span class="dropdown-caret">▾</span>
            </button>
          </div>
        </div>

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
              :max="fromAccountBalance"
              placeholder="0.00"
              class="form-input"
              @pointerdown="typing.onFocus" @keydown="typing.onFocus" @blur="typing.onBlur"
              required
            />
          </div>
          <p v-if="fromAccount" class="form-hint">
            Available: ${{ formatCurrency(fromAccountBalance) }}
          </p>
        </div>

        <div v-if="isBusinessAccount && businessTransferMinutes !== null" class="warning-box">
          <p>Business transfers arrive in about {{ businessTransferMinutes }} minutes.</p>
        </div>

        <div v-if="error" class="error-box">
          {{ error }}
        </div>

        <button
          type="submit"
          class="submit-btn"
          :disabled="!isValid || processing"
        >
          {{ processing ? 'Transferring...' : `Transfer $${formatCurrency(amount || 0)}` }}
        </button>
      </form>

      <!-- From dropdown menu -->

        <div v-if="showFromMenu" class="dropdown-menu bank-account-list" v-bng-scoped-nav="menuScope" v-bng-on-ui-nav:back,menu="menuBack" :style="fromMenuStyle">
          <button
            v-for="account in accounts"
            :key="account.id"
            class="dropdown-item"
            @click.stop="selectFrom(account.id)"
            :disabled="false"
          >
            <span class="item-name">{{ account.name }}</span>
            <span class="item-balance">${{ formatCurrency(account.balance) }}</span>
          </button>
        </div>


      <!-- To dropdown menu -->

        <div v-if="showToMenu" class="dropdown-menu bank-account-list" v-bng-scoped-nav="menuScope" v-bng-on-ui-nav:back,menu="menuBack" :style="toMenuStyle">
          <button
            v-for="account in accounts"
            :key="account.id"
            class="dropdown-item"
            @click.stop="selectTo(account.id)"
            :disabled="account.id === fromAccountId" :bng-no-nav="account.id === fromAccountId ? 'true' : null"
          >
            <span class="item-name">{{ account.name }}</span>
            <span class="item-balance">${{ formatCurrency(account.balance) }}</span>
          </button>
        </div>

    </div>
  </div>
</template>

<script setup>

import { vBngOnUiNav, vBngScopedNav } from "@/common/directives"
import { useCefTyping } from "../../composables/useCefTyping.js"
import { amountValue } from "../../utils/amountValue.js"
const typing = useCefTyping()

import { reportUiFailure } from "../../utils/safeLua.js"

import { ref, computed, nextTick, onMounted, onBeforeUnmount } from 'vue'
import { lua } from '@/bridge'

const emit = defineEmits(['return'])
const props = defineProps({ sourceAccountId: { type: String, default: '' } })

const accounts = ref([])
const fromAccountId = ref('')
const toAccountId = ref('')
const amount = ref('')
const processing = ref(false)
const error = ref('')
const businessTransferMinutes = ref(null)
const fromAccount = computed(() => {
  return accounts.value.find(a => a.id === fromAccountId.value)
})

const fromAccountBalance = computed(() => {
  return fromAccount.value?.balance || 0
})

const toAccount = computed(() => {
  return accounts.value.find(a => a.id === toAccountId.value)
})

const isBusinessAccount = computed(() => {
  return fromAccount.value?.type === 'business'
})

const isValid = computed(() => {
  return (
    fromAccountId.value &&
    toAccountId.value &&
    fromAccountId.value !== toAccountId.value &&
    amount.value > 0 &&
    amount.value <= fromAccountBalance.value
  )
})

const formatCurrency = (val) => {
  const num = typeof val === 'string' ? parseFloat(val) : (val || 0)
  return num.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const close = () => {
  emit('return', false)
  amount.value = 0
  error.value = ''
  fromAccountId.value = ''
  toAccountId.value = ''
}

const handleSubmit = async () => {
  if (!isValid.value || processing.value) return

  error.value = ''
  processing.value = true

  try {
    const transferAmount = parseFloat(amount.value)
    const result = await lua.overhaul_career_economy_bank.transfer(
      fromAccountId.value,
      toAccountId.value,
      transferAmount
    )

    if (result) {
      emit('return', true)
    } else {
      error.value = 'Transfer failed. Please check your balance and try again.'
    }
  } catch (e) {
    reportUiFailure(e, "Failed to transfer:")
    error.value = 'Transfer failed. Please try again.'
  } finally {
    processing.value = false
  }
}

onMounted(async () => {
  try {
    const data = await lua.overhaul_career_economy_bank.getAccounts()
    accounts.value = Array.isArray(data) ? data : []
    fromAccountId.value = accounts.value.find(account => account.id === props.sourceAccountId)?.id || accounts.value[0]?.id || ''
    toAccountId.value = accounts.value.find(account => account.id !== fromAccountId.value)?.id || ''
    businessTransferMinutes.value = Math.ceil(await lua.overhaul_career_economy_bank.getBusinessTransferDuration() / 60)
  } catch (e) {
    reportUiFailure(e, "Failed to load accounts:")
  }
})

const amountNav = event => {
  event?.stopPropagation()
  const { name, value } = event?.detail || {}
  if (!value || name === "ok") return
  const delta = { focus_l: -0.01, focus_r: 0.01, tab_l: -100, tab_r: 100 }[name] || 0
  const next = name === "context" ? fromAccountBalance.value : (Number(amount.value) || 0) + delta
  amount.value = amountValue(next, { min: 0, max: fromAccountBalance.value, step: 0.01 })
}

import { useDropdown } from "../../composables/useDropdown.js"
const showFromMenu=ref(false),showToMenu=ref(false),fromAnchor=ref(null),toAnchor=ref(null),fromMenuStyle=ref({}),toMenuStyle=ref({})
const positionMenu = (anchorEl, menuStyleRef) => {
  if (!anchorEl) return
  const rect = anchorEl.getBoundingClientRect()
  menuStyleRef.value = {
    position: 'fixed',
    top: rect.bottom + 'px',
    left: rect.left + 'px',
    width: rect.width + 'px'
  }
}

const { toggle: openFromMenu } = useDropdown({
  open: showFromMenu,
  beforeToggle: () => { showToMenu.value = false },
  positionTiming: "beforeOpen",
  afterOpen: () => nextTick(() => document.querySelector(".bank-account-list .dropdown-item:not([disabled])")?.focus()),
  place: () => positionMenu(fromAnchor.value, fromMenuStyle),
})
const { toggle: openToMenu } = useDropdown({
  open: showToMenu,
  beforeToggle: () => { showFromMenu.value = false },
  positionTiming: "beforeOpen",
  afterOpen: () => nextTick(() => document.querySelector(".bank-account-list .dropdown-item:not([disabled])")?.focus()),
  place: () => positionMenu(toAnchor.value, toMenuStyle),
})

const handleOutside = (e) => {
  const clickedDropdown = e.target.closest('.dropdown-menu')
  const clickedTrigger = e.target.closest('.dropdown-trigger')

  if (!clickedDropdown && !clickedTrigger) {
    if (showFromMenu.value || showToMenu.value) {
      showFromMenu.value = false
      showToMenu.value = false
    }
  }
}

const selectFrom = (id) => {
  fromAccountId.value = id
  showFromMenu.value = false
  fromAnchor.value?.querySelector("button")?.focus()
}

const selectTo = (id) => {
  toAccountId.value = id
  showToMenu.value = false
  toAnchor.value?.querySelector("button")?.focus()
}


const closeModal = () => {
  showFromMenu.value = false
  showToMenu.value = false
  close()
}
const menuScope = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}
const menuBack = event => {
  event?.stopPropagation()
  const anchor = showFromMenu.value ? fromAnchor.value : toAnchor.value
  showFromMenu.value = false
  showToMenu.value = false
  nextTick(() => anchor?.querySelector("button")?.focus())
  return false
}
onMounted(() => window.addEventListener("click", handleOutside, true))
onBeforeUnmount(() => window.removeEventListener("click", handleOutside, true))

</script>
<style scoped lang="scss">
.transfer-modal-overlay {
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

.transfer-modal {
  background: white;
  border-radius: 16px;
  padding: 20px;
  width: 90%;
  max-width: 500px;
  max-height: 90vh;
  overflow-y: auto;
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

.transfer-arrow {
  display: flex;
  justify-content: center;
  margin: 6px 0;
  color: #64748b;
  font-size: 1.5rem;
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

.warning-box {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px;
  background: #fff7ed;
  border: 1px solid #fed7aa;
  border-radius: 10px;
  color: #92400e;
  margin-bottom: 16px;
  font-size: 0.9rem;
  line-height: 1.2;
}

.error-box {
  padding: 10px;
  background: #fee2e2;
  border: 1px solid #fecaca;
  border-radius: 10px;
  color: #dc2626;
  margin-bottom: 16px;
  font-size: 0.9rem;
  line-height: 1.2;
}

.submit-btn {
  width: 100%;
  padding: 12px;
  background: #1e293b;
  color: white;
  border: none;
  border-radius: 10px;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover:not(:disabled) {
    background: #334155;
  }

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.dropdown-anchor {
  width: 100%;
}

.dropdown-trigger {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px;
  border: 1px solid #cbd5e1;
  border-radius: 10px;
  background: white;
  color: #1e293b;
  cursor: pointer;
}

.dropdown-caret {
  color: #64748b;
}

.dropdown-menu {
  position: absolute;
  background: white;
  border: 1px solid #cbd5e1;
  border-radius: 10px;
  box-shadow: 0 12px 24px rgba(0,0,0,0.12);
  max-height: 160px;
  overflow-y: auto;
  overflow-x: hidden;
  z-index: 10000;

  /* Custom scrollbar matching account history */
  &::-webkit-scrollbar {
    width: 8px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.05);
    border-radius: 4px;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;

    &:hover {
      background: rgba(0, 0, 0, 0.3);
    }
  }
}

.dropdown-item {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 8px 10px;
  background: white;
  border: none;
  color: #1e293b;
  cursor: pointer;
  font-size: 0.9rem;
}

.dropdown-item:hover {
  background: #f1f5f9;
}

.dropdown-item:disabled {
  opacity: .5;
  cursor: not-allowed;
}

.item-name {
  font-weight: 600;
  font-size: 0.9rem;
}

.item-balance {
  color: #64748b;
  font-size: 0.85rem;
}
</style>
