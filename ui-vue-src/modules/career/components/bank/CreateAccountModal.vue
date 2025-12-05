<template>
  <div v-if="show" class="create-account-modal-overlay" @click.self="close">
    <div class="create-account-modal">
      <div class="modal-header">
        <h3 class="modal-title">New Account</h3>
        <button class="close-btn" @click="close">×</button>
      </div>
      <form @submit.prevent="handleSubmit" class="form">
        <div class="form-group">
          <label class="form-label">Account Name</label>
          <input
            v-model="accountName"
            type="text"
            placeholder="e.g., Emergency Fund"
            class="form-input"
            @focus="onInputFocus"
            @blur="onInputBlur"
            v-bng-text-input
            required
          />
        </div>

        <div class="form-group">
          <label class="form-label">Account Type</label>
          <div class="account-types">
            <button
              v-for="type in accountTypes"
              :key="type.value"
              type="button"
              :class="['account-type-btn', { active: selectedType === type.value }]"
              @click="selectedType = type.value"
            >
              <div class="type-icon" :class="type.iconClass">
                {{ type.value === 'checking' ? '$' : '💰' }}
              </div>
              <div class="type-info">
                <h4 class="type-name">{{ type.label }}</h4>
                <p class="type-desc">{{ type.description }}</p>
              </div>
              <div v-if="selectedType === type.value" class="type-check">
                ✓
              </div>
            </button>
          </div>
        </div>

        <div class="form-group">
          <label class="form-label">Initial Deposit (Optional)</label>
          <div class="input-with-prefix">
            <span class="input-prefix">$</span>
            <input
              v-model.number="initialDeposit"
              type="number"
              step="0.01"
              min="0"
              :max="walletBalance"
              placeholder="0.00"
              class="form-input"
              @focus="onInputFocus"
              @blur="onInputBlur"
              v-bng-text-input
            />
          </div>
          <p class="form-hint">Available: ${{ formatCurrency(walletBalance) }}</p>
        </div>

        <button
          type="submit"
          class="submit-btn"
          :disabled="!accountName.trim() || processing"
        >
          {{ processing ? 'Creating...' : 'Create Account' }}
        </button>
      </form>
    </div>
  </div>
</template>

<script setup>
import { ref, watch, onMounted } from 'vue'
import { lua } from '@/bridge'
import { vBngTextInput } from '@/common/directives'

const props = defineProps({
  show: {
    type: Boolean,
    default: false
  }
})

const emit = defineEmits(['close', 'created'])

const accountName = ref('')
const selectedType = ref('checking')
const initialDeposit = ref(0)
const walletBalance = ref(0)
const processing = ref(false)

const accountTypes = [
  {
    value: 'checking',
    label: 'Checking',
    iconClass: 'icon-checking',
    description: 'For everyday transactions'
  },
  {
    value: 'savings',
    label: 'Savings',
    iconClass: 'icon-savings',
    description: 'For saving money'
  }
]

const formatCurrency = (amount) => {
  return (amount || 0).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

const onInputFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onInputBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}

const close = () => {
  emit('close')
  accountName.value = ''
  selectedType.value = 'checking'
  initialDeposit.value = 0
}

const handleSubmit = async () => {
  if (!accountName.value.trim() || processing.value) return

  processing.value = true
  try {
    await lua.career_modules_bank.createAccount(
      accountName.value.trim(),
      selectedType.value,
      initialDeposit.value || 0
    )
    emit('created')
    close()
  } catch (e) {
    console.error('Failed to create account:', e)
  } finally {
    processing.value = false
  }
}

watch(() => props.show, async (newVal) => {
  if (newVal) {
    try {
      walletBalance.value = await lua.career_modules_playerAttributes.getAttributeValue('money') || 0
    } catch (e) {
      console.error('Failed to load wallet balance:', e)
    }
  }
})

onMounted(async () => {
  if (props.show) {
    try {
      walletBalance.value = await lua.career_modules_playerAttributes.getAttributeValue('money') || 0
    } catch (e) {
      console.error('Failed to load wallet balance:', e)
    }
  }
})
</script>

<style scoped lang="scss">
.create-account-modal-overlay {
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

.create-account-modal {
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
  font-size: 0.9rem;
  line-height: 1.2;
}

.form-input {
  width: 100%;
  padding: 10px;
  border: 1px solid #cbd5e1;
  border-radius: 8px;
  font-size: 0.95rem;
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
  font-size: 0.8rem;
  color: #64748b;
  margin-top: 4px;
}

.account-types {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.account-type-btn {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  padding: 14px;
  border: 2px solid #e2e8f0;
  border-radius: 10px;
  background: white;
  cursor: pointer;
  transition: all 0.2s ease;
  text-align: left;
  min-height: 72px;

  &:hover {
    border-color: #cbd5e1;
  }

  &.active {
    border-color: #3b82f6;
    background: #eff6ff;
  }
}

.type-icon {
  width: 44px;
  height: 44px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: white;
  font-size: 1.4rem;
  flex-shrink: 0;
}

.icon-checking {
  background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%);
}

.icon-savings {
  background: linear-gradient(135deg, #10b981 0%, #059669 100%);
}

.type-info {
  flex: 1;
  display: flex;
  flex-direction: column;
  justify-content: center;
  min-height: 0;
}

.type-name {
  font-weight: 700;
  margin: 0 0 2px 0;
  color: #1e293b;
  font-size: 0.95rem;
  line-height: 1.2;
}

.type-desc {
  font-size: 0.8rem;
  color: #64748b;
  margin: 0;
  line-height: 1.2;
}

.type-check {
  color: #3b82f6;
  font-size: 1.2rem;
  display: flex;
  align-items: center;
}

.submit-btn {
  width: 100%;
  padding: 14px;
  background: #1e293b;
  color: white;
  border: none;
  border-radius: 8px;
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
</style>

