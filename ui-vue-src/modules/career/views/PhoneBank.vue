<template>
  <PhoneWrapper app-name="Bank" status-font-color="#000000" status-blend-mode="">
    <div class="phone-bank">
      <div class="section">
        <div class="total-balance-card">
          <p class="balance-label">Total Balance</p>
          <h2 class="balance-amount">${{ formatCurrency(totalBalance) }}</h2>
          <div class="balance-actions">
            <button class="action-btn transfer-btn" @click="showTransferModal = true">
              ⇄ Transfer
            </button>
            <button class="action-btn create-btn" @click="showCreateModal = true">
              + New Account
            </button>
          </div>
        </div>
      </div>

      <div class="section">
        <div class="section-title">My Accounts</div>
        <div class="section-card">
          <div v-if="accounts.length === 0" class="none">No accounts yet</div>
          <div v-else class="accounts-list">
            <button 
              v-for="account in accounts" 
              :key="account.id"
              class="account-card"
              @click="selectAccount(account.id)"
            >
              <div class="account-icon" :class="getAccountIconClass(account)">
                {{ account.type === 'business' ? '🏢' : account.accountType === 'savings' ? '💰' : '$' }}
              </div>
              <div class="account-info">
                <h4 class="account-name">{{ account.name }}</h4>
              </div>
              <div class="account-balance">
                <p class="balance">${{ formatCurrency(account.balance) }}</p>
                <p class="account-type-label">{{ account.type === 'business' ? 'Business' : (account.accountType || 'Checking').charAt(0).toUpperCase() + (account.accountType || 'Checking').slice(1) }}</p>
              </div>
            </button>
          </div>
        </div>
      </div>

      <div v-if="pendingTransfers.length > 0" class="section">
        <div class="section-title">Pending Transfers</div>
        <div class="section-card">
          <div class="pending-transfers-list">
            <div 
              v-for="transfer in pendingTransfers" 
              :key="transfer.id"
              class="pending-transfer-item"
            >
              <div class="transfer-info">
                <p class="transfer-amount">${{ formatCurrency(transfer.amount) }}</p>
                <p class="transfer-accounts">
                  {{ getAccountName(transfer.fromAccountId) }} → {{ getAccountName(transfer.toAccountId) }}
                </p>
                <p class="transfer-time">Completes in {{ formatTimeRemaining(transfer.completesAt) }}</p>
              </div>
              <button class="cancel-btn" @click.stop="cancelTransfer(transfer.id)">Cancel</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <TransferModal 
      :show="showTransferModal"
      @close="showTransferModal = false"
      @transferred="handleTransferred"
    />

    <CreateAccountModal 
      :show="showCreateModal"
      @close="showCreateModal = false"
      @created="handleCreated"
    />
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import TransferModal from '../components/bank/TransferModal.vue'
import CreateAccountModal from '../components/bank/CreateAccountModal.vue'
import { lua } from '@/bridge'
import { useRouter } from 'vue-router'

const router = useRouter()

const accounts = ref([])
const pendingTransfers = ref([])
const showTransferModal = ref(false)
const showCreateModal = ref(false)
let refreshInterval = null

const totalBalance = computed(() => {
  if (!Array.isArray(accounts.value)) return 0
  return accounts.value.reduce((sum, acc) => sum + (acc.balance || 0), 0)
})

const formatCurrency = (amount) => {
  return (amount || 0).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const formatAccountType = (account) => {
  if (account.type === 'business') {
    return 'Business Account'
  }
  return account.accountType || 'Personal'
}

const getAccountIcon = (account) => {
  return icons.beamCurrency
}

const getAccountIconClass = (account) => {
  if (account.type === 'business') {
    return 'icon-business'
  }
  if (account.accountType === 'savings') {
    return 'icon-savings'
  }
  return 'icon-checking'
}

const getAccountName = (accountId) => {
  if (!Array.isArray(accounts.value)) return 'Unknown'
  const account = accounts.value.find(a => a.id === accountId)
  return account ? account.name : 'Unknown'
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

const selectAccount = (accountId) => {
  router.push({ name: 'phone-bank-account', params: { accountId } })
}

const refreshAccounts = async () => {
  try {
    accounts.value = await lua.career_modules_bank.getAccounts() || []
  } catch (e) {
    console.error('Failed to load accounts:', e)
    accounts.value = []
  }
}

const refreshPendingTransfers = async () => {
  try {
    pendingTransfers.value = await lua.career_modules_bank.getPendingTransfers() || []
  } catch (e) {
    console.error('Failed to load pending transfers:', e)
    pendingTransfers.value = []
  }
}

const cancelTransfer = async (transferId) => {
  try {
    await lua.career_modules_bank.cancelPendingTransfer(transferId)
    await refreshAccounts()
    await refreshPendingTransfers()
  } catch (e) {
    console.error('Failed to cancel transfer:', e)
  }
}

const handleTransferred = async () => {
  await refreshAccounts()
  await refreshPendingTransfers()
}

const handleCreated = async () => {
  await refreshAccounts()
}

onMounted(async () => {
  await refreshAccounts()
  await refreshPendingTransfers()
  
  refreshInterval = setInterval(async () => {
    await refreshPendingTransfers()
    await refreshAccounts()
  }, 1000)
})

onBeforeUnmount(() => {
  if (refreshInterval) {
    clearInterval(refreshInterval)
    refreshInterval = null
  }
  showTransferModal.value = false
  showCreateModal.value = false
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-bank {
  padding: 16px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow-y: auto;
  overflow-x: hidden;
  box-sizing: border-box;
  position: relative;
  
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

.section {
  margin-bottom: 20px;
}

.section-title {
  font-weight: 800;
  font-size: 1.4rem;
  margin: 0 0 8px 0;
  line-height: 1.2;
}

.section-card {
  background: #ffffff;
  border: 1px solid #d4e2ff;
  border-radius: 12px;
  padding: 14px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
}

.total-balance-card {
  background: linear-gradient(135deg, #1e293b 0%, #334155 100%);
  color: white;
  border-radius: 16px;
  padding: 16px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
}

.balance-label {
  font-size: 0.9rem;
  opacity: 0.8;
  margin: 0 0 6px 0;
  line-height: 1.2;
}

.balance-amount {
  font-size: 2.3rem;
  font-weight: 800;
  margin: 0 0 6px 0;
  line-height: 1;
}

.balance-actions {
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

  .btn-icon {
    font-size: 1.05rem;
  }
}

.transfer-btn {
  background: rgba(255, 255, 255, 0.2);
  color: white;

  &:hover {
    background: rgba(255, 255, 255, 0.3);
  }
}

.create-btn {
  background: white;
  color: #1e293b;

  &:hover {
    background: rgba(255, 255, 255, 0.9);
  }
}

.accounts-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.account-card {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px;
  min-height: 52px;
  background: #eef4ff;
  border: 1px solid #c9d8ff;
  border-radius: 12px;
  text-align: left;
  width: 100%;
  border: 0;
  color: inherit;
  transition: transform 0.08s ease, box-shadow 0.2s ease;
  cursor: pointer;

  &:hover {
    transform: translateY(-1px);
    box-shadow: 0 2px 8px rgba(16, 24, 40, .07);
  }
}

.account-icon {
  width: 40px;
  height: 40px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: white;
  font-size: 1.3rem;
  flex-shrink: 0;
  margin: 0;
}

.icon-checking {
  background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%);
}

.icon-savings {
  background: linear-gradient(135deg, #10b981 0%, #059669 100%);
}

.icon-business {
  background: linear-gradient(135deg, #8b5cf6 0%, #7c3aed 100%);
}

.account-info {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
}

.account-name {
  font-weight: 700;
  margin: 0;
  font-size: 1.1rem;
  line-height: 1.2;
}

.account-type {
  font-size: 0.8rem;
  color: #64748b;
  line-height: 1.2;
}

.account-balance {
  text-align: right;
  display: flex;
  flex-direction: column;
  justify-content: center;
}

.balance {
  font-weight: 700;
  font-size: 1.25rem;
  margin: 0;
  line-height: 1.2;
}

.account-type-label {
  font-size: 0.7rem;
  color: #64748b;
  text-transform: capitalize;
  line-height: 1.2;
  margin: 1px 0 0 0;
  font-weight: 400;
}

.pending-transfers-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.pending-transfer-item {
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

.transfer-accounts {
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

.none {
  color: #64748b;
  padding: 30px 20px;
  text-align: center;
  font-size: 0.95rem;
  font-weight: 500;
  display: block;
}
</style>

