<template>
  <PhoneWrapper app-name="Account" status-font-color="#000000" status-blend-mode="">
    <div class="phone-account-details">
      <div v-if="!account" class="none">Loading…</div>
      <div v-else class="content">
        <div class="account-header">
          <p class="account-name">{{ account.name }}</p>
          <h2 class="account-balance">${{ formatCurrency(account.balance) }}</h2>
          <div class="actions-section">
            <button class="action-btn deposit-btn" @click="showDepositModal = true">
              ↓ Deposit
            </button>
            <button 
              class="action-btn withdraw-btn" 
              @click="showWithdrawModal = true"
              :disabled="account.type === 'business'"
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
          <div class="history-scroll-container">
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
          <button class="settings-btn" @click="router.push({ name: 'phone-bank-rename', params: { accountId: account.id } })">
            Rename
          </button>
          <button class="settings-btn delete-btn" @click="showDeleteConfirm = true">
            Delete
          </button>
        </div>
      </div>
    </div>

    <div v-if="showDeleteConfirm" class="delete-confirm-overlay" @click.self="showDeleteConfirm = false">
      <div class="delete-confirm-modal">
        <h3>Delete Account?</h3>
        <p>This will withdraw all funds and close the account. This action cannot be undone.</p>
        <div class="confirm-actions">
          <button class="confirm-btn delete" @click.stop="handleDelete">Delete</button>
          <button class="confirm-btn cancel" @click.stop="showDeleteConfirm = false">Cancel</button>
        </div>
      </div>
    </div>

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
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import DepositModal from '../components/bank/DepositModal.vue'
import WithdrawModal from '../components/bank/WithdrawModal.vue'
import { lua } from '@/bridge'
import { useRouter, useRoute } from 'vue-router'

const router = useRouter()
const route = useRoute()

const account = ref(null)
const pendingTransfers = ref([])
const transactions = ref([])
const showDeleteConfirm = ref(false)
const showDepositModal = ref(false)
const showWithdrawModal = ref(false)
let refreshInterval = null

const formatCurrency = (amount) => {
  return (amount || 0).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const getAccountName = (accountId) => {
  return 'Account'
}

const formatTimeRemaining = (completesAt) => {
  const now = Math.floor(Date.now() / 1000)
  const remaining = Math.max(0, completesAt - now)
  const minutes = Math.floor(remaining / 60)
  const seconds = remaining % 60
  if (minutes > 0) {
    return `${minutes}m ${seconds}s`
  }
  return `${seconds}s`
}

const formatDate = (timestamp) => {
  const date = new Date(timestamp * 1000)
  const now = new Date()
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
  return ''
}

const getTransactionAmountClass = (amount) => {
  if ((amount || 0) >= 0) {
    return 'positive'
  }
  return 'negative'
}

const refreshAccount = async () => {
  try {
    const accounts = await lua.career_modules_bank.getAccounts() || []
    account.value = accounts.find(a => a.id === route.params.accountId)
  } catch (e) {
    console.error('Failed to load account:', e)
  }
}

const refreshPendingTransfers = async () => {
  try {
    const allTransfers = await lua.career_modules_bank.getPendingTransfers() || []
    pendingTransfers.value = allTransfers.filter(t => 
      t.fromAccountId === route.params.accountId || 
      t.toAccountId === route.params.accountId
    )
  } catch (e) {
    console.error('Failed to load pending transfers:', e)
  }
}

const refreshTransactions = async () => {
  try {
    if (account.value) {
      transactions.value = await lua.career_modules_bank.getAccountTransactions(account.value.id, 20) || []
    }
  } catch (e) {
    console.error('Failed to load transactions:', e)
  }
}

const handleDelete = async () => {
  if (!account.value) return

  try {
    const balance = account.value.balance || 0
    if (balance > 0) {
      await lua.career_modules_bank.withdraw(account.value.id, balance)
    }
    await lua.career_modules_bank.deleteAccount(account.value.id)
    router.push({ name: 'phone-bank' })
  } catch (e) {
    console.error('Failed to delete account:', e)
  } finally {
    showDeleteConfirm.value = false
  }
}

const cancelTransfer = async (transferId) => {
  try {
    await lua.career_modules_bank.cancelPendingTransfer(transferId)
    await refreshAccount()
    await refreshPendingTransfers()
  } catch (e) {
    console.error('Failed to cancel transfer:', e)
  }
}

const handleDeposited = async () => {
  await refreshAccount()
  await refreshTransactions()
}

const handleWithdrawn = async () => {
  await refreshAccount()
  await refreshTransactions()
}

onMounted(async () => {
  await refreshAccount()
  await refreshPendingTransfers()
  await refreshTransactions()
  
  refreshInterval = setInterval(async () => {
    await refreshPendingTransfers()
    await refreshAccount()
    await refreshTransactions()
  }, 1000)
})

onBeforeUnmount(() => {
  if (refreshInterval) {
    clearInterval(refreshInterval)
    refreshInterval = null
  }
  showDeleteConfirm.value = false
  showDepositModal.value = false
  showWithdrawModal.value = false
})

</script>

<style scoped lang="scss">
:deep(.phone-content) {
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

