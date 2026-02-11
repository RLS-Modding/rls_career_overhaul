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
  background: linear-gradient(180deg, #ffffff 0%, #f0f6ff 100%);
}

.phone-loan-settings {
  padding: 10px;
  padding-top: 60px;
  color: #0f172a;
  height: 95%;
  overflow-y: auto;
  box-sizing: border-box;
}

.section { margin-bottom: 14px; }

.section-title {
  font-weight: 800;
  font-size: 1.4rem;
  margin: 6px 2px;
}

.section-card {
  background: #ffffff;
  border: 1px solid #d4e2ff;
  border-radius: 14px;
  padding: 10px;
  box-shadow: 0 1px 2px rgba(16, 24, 40, .04), 0 4px 12px rgba(16, 24, 40, .05);
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
  background: rgba(0, 0, 0, 0.15);
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

.toggle-label input[type="checkbox"]:checked + .toggle-slider { background: #cc4c00; }
.toggle-label input[type="checkbox"]:checked + .toggle-slider::before { transform: translateX(20px); }
.toggle-text { color: #0f172a; font-weight: 600; }
</style>
