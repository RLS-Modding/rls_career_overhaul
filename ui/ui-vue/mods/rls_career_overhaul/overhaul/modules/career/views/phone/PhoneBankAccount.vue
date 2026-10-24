<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="phone-bank-account-root">
    <div class="phone-account-details" v-bng-ui-nav-scroll>
      <div v-if="!account" class="none">Loading…</div>
      <div v-else class="content">
        <div class="account-header">
          <p class="account-name">{{ account.name }}</p>
          <p v-if="account.type !== 'business' && account.accountType === 'savings'" class="savings-meta">
            Accrued: ${{ formatCurrency(account.accruedInterest || 0) }}. Next payout in {{ formatPayoutEta(account.nextPayoutIn) }}
          </p>
          <h2 class="account-balance">${{ formatCurrency(account.balance) }}</h2>
          <div class="actions-section">
            <button class="action-btn deposit-btn" @click="showDepositModal = true">
              ↓ Deposit
            </button>
            <button
              v-if="account.type === 'business'"
              class="action-btn transfer-btn"
              @click="showTransferModal = true"
            >
              ⇄ Transfer
            </button>
            <button
              v-else
              class="action-btn withdraw-btn"
              @click="showWithdrawModal = true"
            >
              ↑ Withdraw
            </button>
          </div>
        </div>

        <div class="pending-section" v-if="pendingTransfers.length > 0">
          <h3 class="section-title">Pending Transfers</h3>
          <div class="pending-list">
            <div
              v-for="transfer in pendingTransfers"
              :key="transfer.id"
              class="pending-item"
            >
              <div class="transfer-info">
                <p class="transfer-amount">${{ formatCurrency(transfer.amount) }}</p>
                <p class="transfer-dest">To: {{ getAccountName(transfer.toAccountId) }}</p>
                <p class="transfer-time">Completes in {{ formatTimeRemaining(transfer.completesAt) }}</p>
              </div>
              <button class="cancel-btn" @click="cancelTransfer(transfer.id)">Cancel</button>
            </div>
          </div>
        </div>

        <div class="history-card">
          <h3 class="history-title">History</h3>
          <div class="history-scroll-container" v-bng-ui-nav-scroll.force>
            <div v-if="transactions.length === 0" class="no-history">
              <p>No transactions yet</p>
            </div>
            <div v-else class="history-list">
              <div
                v-for="transaction in transactions"
                :key="transaction.id"
                class="history-item"
              >
                <div class="transaction-info">
                  <p class="transaction-type">{{ getTransactionTypeLabel(transaction) }}</p>
                  <p class="transaction-date">{{ formatDate(transaction.timestamp) }}</p>
                </div>
                <div class="transaction-amount" :class="getTransactionAmountClass(transaction.amount)">
                  {{ getTransactionAmountPrefix(transaction.amount) }}${{ formatCurrency(Math.abs(transaction.amount || 0)) }}
                </div>
              </div>
            </div>
          </div>
        </div>

        <div v-if="account.type !== 'business'" class="settings-section">
          <button class="settings-btn" @click="openRename">
            Rename
          </button>
          <button class="settings-btn delete-btn" @click="showDeleteConfirm = true">
            Delete
          </button>
        </div>
      </div>
    </div>

    <PhoneLayer v-if="showDeleteConfirm" class="delete-confirm-overlay" @click.self="showDeleteConfirm = false" label="Delete account" @close="showDeleteConfirm = false">
      <div class="delete-confirm-modal">
        <h3>Delete Account?</h3>
        <p>This will withdraw all funds and close the account. This action cannot be undone.</p>
        <div class="confirm-actions">
          <button class="confirm-btn delete" @click.stop="handleDelete">Delete</button>
          <button class="confirm-btn cancel" bng-scoped-nav-autofocus @click.stop="showDeleteConfirm = false">Cancel</button>
        </div>
      </div>
    </PhoneLayer>

    <DepositModal
      :show="showDepositModal"
      :account-id="account?.id || ''"
      @close="showDepositModal = false"
      @deposited="handleDeposited"
    />

    <WithdrawModal
      :show="showWithdrawModal"
      :account-id="account?.id || ''"
      :account-balance="account?.balance || 0"
      @close="showWithdrawModal = false"
      @withdrawn="handleWithdrawn"
    />
    <TransferModal
      :show="showTransferModal"
      :source-account-id="account?.id || ''"
      @close="showTransferModal = false"
      @transferred="refreshBank"
    />
  </div>
</template>

<script setup>
import { vBngUiNavScroll } from '@/common/directives'
import PhoneLayer from '../../components/phone/PhoneLayer.vue'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
usePhoneScreen()
import { reportUiFailure } from "../../utils/safeLua"

import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import DepositModal from '../../components/bank/DepositModal.vue'
import WithdrawModal from '../../components/bank/WithdrawModal.vue'
import TransferModal from '../../components/bank/TransferModal.vue'
import { lua } from '@/bridge'
import { useRoute } from 'vue-router'
import { useEvents } from '@/services/events'

const route = useRoute()
const events = useEvents()

const openRename = () => {
  if (!account.value?.id) return
  lua.extensions.ui_router.navigate('phone-bank-rename', { accountId: account.value.id })
}

const accounts = ref([])
const account = computed(() => accounts.value.find(item => item.id === route.params.accountId))
const pendingTransfers = ref([])
const transactions = ref([])
const showDeleteConfirm = ref(false)
const showDepositModal = ref(false)
const showWithdrawModal = ref(false)
const showTransferModal = ref(false)
const nowSeconds = ref(Math.floor(Date.now() / 1000))
const savingsElapsed = ref(0)
let clockTimer = null
let clockSampleAt = Date.now()
let simulationSpeed = 1
let physicsRunning = true
let simulationEventVersion = 0
let isUnmounted = false
let refreshPromise = null
let refreshRequested = false

function updateClock() {
  const now = Date.now()
  nowSeconds.value = Math.floor(now / 1000)
  if (physicsRunning) savingsElapsed.value += Math.max(0, now - clockSampleAt) / 1000 * simulationSpeed
  clockSampleAt = now
}

function handlePhysicsStateChanged(enabled) {
  updateClock()
  simulationEventVersion++
  physicsRunning = enabled === true
}

function handleSimulationSpeedChanged(speed) {
  updateClock()
  simulationEventVersion++
  simulationSpeed = Math.max(0, Number(speed) || 0)
}

const formatCurrency = (amount) => {
  return (amount || 0).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const formatPayoutEta = (seconds) => {
  const s = Math.max(0, Math.ceil((Number(seconds) || 0) - savingsElapsed.value))
  const m = Math.floor(s / 60)
  const r = s % 60
  if (m >= 60) {
    const h = Math.floor(m / 60)
    const mm = m % 60
    return `${h}h ${mm}m`
  }
  if (m > 0) return `${m}m ${r}s`
  return `${r}s`
}

const getAccountName = (accountId) => {
  const match = accounts.value.find(a => a.id === accountId)
  if (match?.name) return match.name
  if (account.value?.id === accountId && account.value.name) return account.value.name
  return 'Account'
}

const formatTimeRemaining = (completesAt) => {
  const remaining = Math.max(0, completesAt - nowSeconds.value)
  const minutes = Math.floor(remaining / 60)
  const seconds = remaining % 60
  if (minutes > 0) {
    return `${minutes}m ${seconds}s`
  }
  return `${seconds}s`
}

const formatDate = (timestamp) => {
  const date = new Date(timestamp * 1000)
  const now = new Date(nowSeconds.value * 1000)
  const diffMs = now - date
  const diffMins = Math.floor(diffMs / 60000)
  const diffHours = Math.floor(diffMs / 3600000)
  const diffDays = Math.floor(diffMs / 86400000)

  if (diffMins < 1) return 'Just now'
  if (diffMins < 60) return `${diffMins}m ago`
  if (diffHours < 24) return `${diffHours}h ago`
  if (diffDays < 7) return `${diffDays}d ago`

  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

const getTransactionTypeLabel = (transaction) => {
  const amount = transaction.amount || 0
  const label = transaction.label

  if (label) {
    return label
  }

  if (amount >= 0) {
    return 'Deposit'
  } else {
    return 'Withdrawal'
  }
}

const getTransactionAmountPrefix = (amount) => {
  if ((amount || 0) >= 0) {
    return '+'
  }
  return '-'
}

const getTransactionAmountClass = (amount) => {
  if ((amount || 0) >= 0) {
    return 'positive'
  }
  return 'negative'
}

const refreshBank = () => {
  if (isUnmounted) return Promise.resolve()
  refreshRequested = true
  if (refreshPromise) return refreshPromise
  refreshPromise = (async () => {
    do {
      refreshRequested = false
      const accountId = route.params.accountId
      const [accountList, transfers, history] = await Promise.all([
        lua.overhaul_career_economy_bank.getAccounts(),
        lua.overhaul_career_economy_bank.getPendingTransfers(),
        lua.overhaul_career_economy_bank.getAccountTransactions(accountId, 20),
      ])
      if (isUnmounted) return
      const nextAccounts = Object.values(accountList || {})
      const nextTransfers = Object.values(transfers || {}).filter(t => t.fromAccountId === accountId || t.toAccountId === accountId)
      const nextTransactions = Object.values(history || {})
      if (JSON.stringify(accounts.value) !== JSON.stringify(nextAccounts)) accounts.value = nextAccounts
      if (JSON.stringify(pendingTransfers.value) !== JSON.stringify(nextTransfers)) pendingTransfers.value = nextTransfers
      if (JSON.stringify(transactions.value) !== JSON.stringify(nextTransactions)) transactions.value = nextTransactions
      clockSampleAt = Date.now()
      savingsElapsed.value = 0
    } while (refreshRequested && !isUnmounted)
  })().catch(e => {
    if (!isUnmounted) reportUiFailure(e, "Failed to load account: (PhoneBankAccount)")
  }).finally(() => { refreshPromise = null })
  return refreshPromise
}

const handleAccountUpdate = () => refreshBank()

const handleDelete = async () => {
  if (!account.value) return

  try {
    const balance = account.value.balance || 0
    if (balance > 0) {
      await lua.overhaul_career_economy_bank.withdraw(account.value.id, balance)
    }
    await lua.overhaul_career_economy_bank.deleteAccount(account.value.id)
    await lua.extensions.ui_router.navigate('phone-bank')
  } catch (e) {
    reportUiFailure(e, "Failed to delete account: (PhoneBankAccount)")
  } finally {
    showDeleteConfirm.value = false
  }
}

const cancelTransfer = async (transferId) => {
  try {
    await lua.overhaul_career_economy_bank.cancelPendingTransfer(transferId)
    await refreshBank()
  } catch (e) {
    reportUiFailure(e, "Failed to cancel transfer: (PhoneBankAccount)")
  }
}

const handleDeposited = async () => {
  await refreshBank()
}

const handleWithdrawn = async () => {
  await refreshBank()
}

onMounted(() => {
  events.on('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  events.on('bank:onAccountClosed', handleAccountUpdate)
  events.on('physicsStateChanged', handlePhysicsStateChanged)
  events.on('BullettimeValueChanged', handleSimulationSpeedChanged)
  const version = simulationEventVersion
  Promise.all([lua.simTimeAuthority.get(), lua.simTimeAuthority.getPause()]).then(([speed, paused]) => {
    if (isUnmounted || version !== simulationEventVersion) return
    updateClock()
    simulationSpeed = Math.max(0, Number(speed) || 0)
    physicsRunning = paused !== true
  }).catch(e => {
    if (!isUnmounted) reportUiFailure(e, "Failed to load simulation clock: (PhoneBankAccount)")
  })
  clockTimer = setInterval(updateClock, 1000)
  return refreshBank()
})

onBeforeUnmount(() => {
  isUnmounted = true
  events.off('bank:onOverhaulAccountUpdate', handleAccountUpdate)
  events.off('bank:onAccountClosed', handleAccountUpdate)
  events.off('physicsStateChanged', handlePhysicsStateChanged)
  events.off('BullettimeValueChanged', handleSimulationSpeedChanged)
  clearInterval(clockTimer)
  showDeleteConfirm.value = false
  showDepositModal.value = false
  showWithdrawModal.value = false
  showTransferModal.value = false
})

</script>

<style scoped lang="scss">
.phone-bank-account-root { position: relative; height: 100%; }
.phone-bank-account-root {
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-account-details {
  padding: 16px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow: hidden;
  box-sizing: border-box;
  position: relative;
  display: flex;
  flex-direction: column;
}

.content {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

.account-header {
  background: linear-gradient(135deg, #1e293b 0%, #334155 100%);
  color: white;
  border-radius: 16px;
  padding: 16px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  margin-bottom: 20px;
  flex-shrink: 0;
}

.account-name {
  font-size: 0.9rem;
  opacity: 0.8;
  margin: 0 0 6px 0;
  line-height: 1.2;
}

.savings-meta {
  font-size: 0.72rem;
  opacity: 0.85;
  margin: 0 0 8px 0;
  line-height: 1.25;
  color: rgba(255, 255, 255, 0.92);
}

.account-balance {
  font-size: 2.3rem;
  font-weight: 800;
  margin: 0 0 6px 0;
  line-height: 1;
}

.actions-section {
  display: flex;
  gap: 8px;
}

.action-btn {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 10px;
  border-radius: 10px;
  border: none;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
}

.deposit-btn {
  background: #10b981;
  color: white;

  &:hover:not(:disabled) {
    background: #059669;
  }
}

.withdraw-btn {
  background: #ef4444;
  color: white;

  &:hover:not(:disabled) {
    background: #dc2626;
  }
}

.transfer-btn {
  background: rgba(255, 255, 255, 0.2);
  color: white;

  &:hover {
    background: rgba(255, 255, 255, 0.3);
  }

  &.focus-visible {
    outline: 2px solid var(--bng-orange-b400, #ff6600);
    outline-offset: 2px;
  }
}

.settings-section {
  flex-shrink: 0;
  padding-top: 20px;
  display: flex;
  gap: 8px;
}

.settings-btn {
  flex: 1;
  padding: 10px;
  background: white;
  border: 1px solid #cbd5e1;
  border-radius: 10px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    background: #f1f5f9;
  }

  &.delete-btn {
    color: #dc2626;
    border-color: #fecaca;

    &:hover {
      background: #fee2e2;
    }
  }
}

.pending-section {
  margin-bottom: 20px;
  flex-shrink: 0;

  .section-title {
    font-weight: 800;
    font-size: 1.2rem;
    margin-bottom: 8px;
    line-height: 1.2;
  }
}

.pending-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.history-card {
  background: #ffffff;
  border: 1px solid #d4e2ff;
  border-radius: 12px;
  padding: 14px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  margin-bottom: 20px;
}

.history-title {
  font-weight: 800;
  font-size: 1.2rem;
  margin: 0 0 8px 0;
  line-height: 1.2;
  flex-shrink: 0;
}

.history-scroll-container {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  min-height: 0;
  padding-bottom: 8px;

  /* Custom scrollbar matching business computer */
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

.history-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.no-history {
  padding: 16px;
  text-align: center;
  color: #64748b;
  font-size: 0.9rem;
}

.history-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px;
  background: white;
  border: 1px solid #e2e8f0;
  border-radius: 12px;
}

.transaction-info {
  flex: 1;
}

.transaction-type {
  font-weight: 700;
  font-size: 0.95rem;
  margin: 0 0 2px 0;
  line-height: 1.2;
  color: #1e293b;
}

.transaction-date {
  font-size: 0.75rem;
  color: #94a3b8;
  margin: 0;
  line-height: 1.2;
}

.transaction-amount {
  font-weight: 700;
  font-size: 1.1rem;
  line-height: 1.2;

  &.positive {
    color: #10b981;
  }

  &.negative {
    color: #ef4444;
  }
}

.pending-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px;
  background: #fff7ed;
  border: 1px solid #fed7aa;
  border-radius: 12px;
}

.transfer-info {
  flex: 1;
}

.transfer-amount {
  font-weight: 700;
  font-size: 1.1rem;
  margin-bottom: 2px;
  line-height: 1.2;
}

.transfer-dest {
  font-size: 0.85rem;
  color: #64748b;
  margin-bottom: 2px;
  line-height: 1.2;
}

.transfer-time {
  font-size: 0.75rem;
  color: #f59e0b;
  line-height: 1.2;
}

.cancel-btn {
  padding: 10px;
  background: #fee2e2;
  color: #dc2626;
  border: 1px solid #fecaca;
  border-radius: 8px;
  font-size: 0.85rem;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.2s ease;

  &:hover {
    background: #fecaca;
  }
}

.delete-confirm-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: rgba(0, 0, 0, 0.7);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.delete-confirm-modal {
  background: white;
  border-radius: 16px;
  padding: 14px;
  max-width: 400px;
  width: 90%;

  h3 {
    font-size: 1.3rem;
    font-weight: 800;
    margin-bottom: 8px;
    line-height: 1.2;
  }

  p {
    color: #64748b;
    margin-bottom: 14px;
    line-height: 1.2;
  }
}

.confirm-actions {
  display: flex;
  gap: 8px;
}

.confirm-btn {
  flex: 1;
  padding: 10px;
  border-radius: 10px;
  font-weight: 600;
  cursor: pointer;
  border: none;
  transition: all 0.2s ease;

  &.delete {
    background: #dc2626;
    color: white;

    &:hover {
      background: #b91c1c;
    }
  }

  &.cancel {
    background: #e2e8f0;
    color: #1e293b;

    &:hover {
      background: #cbd5e1;
    }
  }
}

.none {
  padding: 40px;
  text-align: center;
  color: #64748b;
}
</style>
