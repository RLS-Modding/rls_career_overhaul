<template>
  <PhoneWrapper app-name="Loan Settings">
    <div class="phone-loan-settings">
      <div class="section">
        <div class="section-title">Notifications</div>
        <div class="section-card">
          <div class="toggle-row">
            <label class="toggle-label">
              <input type="checkbox" v-model="notificationsEnabled" @change="toggleNotifications" />
              <span class="toggle-slider"></span>
              <span class="toggle-text">Enable Loan Notifications</span>
            </label>
          </div>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import { lua } from '@/bridge'

const notificationsEnabled = ref(true)

const toggleNotifications = () => {
  lua.career_modules_loans.setNotificationsEnabled(notificationsEnabled.value)
}

onMounted(async () => {
  try {
    const enabled = await lua.career_modules_loans.getNotificationsEnabled()
    notificationsEnabled.value = enabled
  } catch { }
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
    background:
        radial-gradient(110% 80% at 50% -10%, rgba(99, 102, 241, 0.35) 0%, rgba(99, 102, 241, 0) 70%),
        linear-gradient(180deg, #030712 0%, #0b1227 56%, #0f172a 100%);
}

.phone-loan-settings {
    padding: 12px;
    padding-top: 58px;
    color: #e2e8f0;
    height: 95%;
    overflow-y: auto;
    overflow-x: hidden;
    box-sizing: border-box;

    &::-webkit-scrollbar { width: 7px; }
    &::-webkit-scrollbar-track { background: rgba(148, 163, 184, 0.12); border-radius: 999px; }
    &::-webkit-scrollbar-thumb {
        background: rgba(148, 163, 184, 0.4);
        border-radius: 999px;
        &:hover { background: rgba(148, 163, 184, 0.55); }
    }
}

.section {
    margin-bottom: 14px;
}

.section-title {
    font-size: 0.75rem;
    letter-spacing: 0.11em;
    text-transform: uppercase;
    font-weight: 700;
    margin: 2px 3px 8px;
    color: #93c5fd;
    opacity: 0.95;
}

.section-card {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.8) 0%, rgba(15, 23, 42, 0.8) 100%);
    border: 1px solid rgba(148, 163, 184, 0.3);
    border-radius: 14px;
    padding: 12px;
    backdrop-filter: blur(12px);
    box-shadow: 0 10px 30px rgba(2, 6, 23, 0.35);
}

.toggle-row { padding: 8px 0; }

.toggle-label {
    display: flex;
    align-items: center;
    gap: 12px;
    cursor: pointer;
    font-size: 0.95em;
}

.toggle-label input[type="checkbox"] { display: none; }

.toggle-slider {
    position: relative;
    width: 44px;
    height: 24px;
    background: rgba(148, 163, 184, 0.3);
    border-radius: 12px;
    transition: background-color 0.3s ease;
    flex-shrink: 0;
}

.toggle-slider::before {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 20px;
    height: 20px;
    background: white;
    border-radius: 50%;
    transition: transform 0.3s ease;
}

.toggle-label input[type="checkbox"]:checked + .toggle-slider { background: #0ea5e9; }
.toggle-label input[type="checkbox"]:checked + .toggle-slider::before { transform: translateX(20px); }
.toggle-text { color: #f8fafc; font-weight: 600; }
</style>



