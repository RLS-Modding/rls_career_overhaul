<template>
  <PhoneWrapper app-name="Rename Account" status-font-color="#000000" status-blend-mode="">
    <div class="phone-rename">
      <div class="content-card">
        <form @submit.prevent="handleSubmit" class="form">
          <div class="form-group">
            <label class="form-label">Account Name</label>
            <input
              v-model="accountName"
              type="text"
              placeholder="Enter new name"
              class="form-input"
              @focus="onInputFocus"
              @blur="onInputBlur"
              v-bng-text-input
              required
            />
          </div>

          <button
            type="submit"
            class="submit-btn"
            :disabled="!accountName.trim() || accountName === originalName || processing"
          >
            {{ processing ? 'Renaming...' : 'Rename' }}
          </button>
        </form>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import PhoneWrapper from './PhoneWrapper.vue'
import { lua } from '@/bridge'
import { vBngTextInput } from '@/common/directives'

const router = useRouter()
const route = useRoute()

const account = ref(null)
const accountName = ref('')
const originalName = ref('')
const processing = ref(false)

const onInputFocus = () => {
  try { lua.setCEFTyping(true) } catch (_) {}
}

const onInputBlur = () => {
  try { lua.setCEFTyping(false) } catch (_) {}
}

const handleSubmit = async () => {
  if (!accountName.value.trim() || processing.value || !account.value) return

  processing.value = true
  try {
    const success = await lua.career_modules_bank.renameAccount(
      account.value.id,
      accountName.value.trim()
    )
    if (success) {
      router.push({ name: 'phone-bank-account', params: { accountId: account.value.id } })
    }
  } catch (e) {
    console.error('Failed to rename account:', e)
  } finally {
    processing.value = false
  }
}

onMounted(async () => {
  try {
    const accountId = route.params.accountId
    if (accountId) {
      const accounts = await lua.career_modules_bank.getAccounts() || []
      account.value = accounts.find(a => a.id === accountId)
      if (account.value) {
        accountName.value = account.value.name
        originalName.value = account.value.name
      }
    }
  } catch (e) {
    console.error('Failed to load account:', e)
  }
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-rename {
  padding: 16px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow-y: auto;
  overflow-x: hidden;
  box-sizing: border-box;
  display: flex;
  align-items: center;
  justify-content: center;
}

.content-card {
  background: #ffffff;
  border-radius: 12px;
  padding: 20px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
  width: 100%;
  max-width: 500px;
}

.page-title {
  font-size: 1.5rem;
  font-weight: 800;
  margin: 0 0 20px 0;
  color: #1e293b;
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

.submit-btn {
  width: 100%;
  padding: 10px;
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
</style>

