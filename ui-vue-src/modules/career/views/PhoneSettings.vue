<template>
  <PhoneWrapper app-name="Settings">
    <div class="phone-settings">
      <div class="settings-card">
        <div class="setting-group">
          <div class="setting-label">Phone Size</div>
          <div class="option-row">
            <button
              v-for="option in PHONE_SIZE_OPTIONS"
              :key="option.value"
              class="option-button"
              :class="{ active: phoneSettings.phoneSize === option.value }"
              @click="setPhoneSize(option.value)"
            >
              {{ option.label }}
            </button>
          </div>
        </div>

        <div class="setting-group">
          <div class="setting-label">Background Picture URL</div>
          <input
            v-model.trim="backgroundImageInput"
            class="picture-input"
            type="text"
            placeholder="https://example.com/phone-bg.jpg"
            @change="applyBackgroundImage"
          />
          <div class="picture-actions">
            <button class="option-button" @click="applyBackgroundImage">Apply Picture</button>
            <button class="option-button" @click="clearBackgroundImage">Use Color</button>
          </div>
        </div>

        <div class="setting-group">
          <div class="setting-label">Background Color</div>
          <div class="color-row">
            <button
              v-for="color in PHONE_BACKGROUND_OPTIONS"
              :key="color"
              class="color-swatch"
              :class="{ active: phoneSettings.backgroundColor === color }"
              :style="{ backgroundColor: color }"
              @click="setBackgroundColor(color)"
              :title="color"
            ></button>
            <label class="custom-color">
              <span>Custom</span>
              <input
                type="color"
                :value="phoneSettings.backgroundColor"
                @input="setBackgroundColor($event.target.value)"
              />
            </label>
          </div>
        </div>

        <div class="settings-footer">
          <button class="reset-button" @click="resetDefaults">Reset Defaults</button>
          <span class="save-state" :class="{ error: saveError }">{{ saveStateText }}</span>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'
import {
  PHONE_SIZE_OPTIONS,
  PHONE_BACKGROUND_OPTIONS,
  usePhoneSettings,
} from '../composables/usePhoneSettings'

const {
  phoneSettings,
  setPhoneSettings,
  replacePhoneSettings,
  resetPhoneSettings,
  getPhoneSettingsSnapshot,
} = usePhoneSettings()

const saveStateText = ref('')
const saveError = ref(false)

let saveTimer = null
let clearStateTimer = null
const backgroundImageInput = ref(phoneSettings.backgroundImage || '')

function setSaveState(text, isError = false) {
  saveStateText.value = text
  saveError.value = isError
  if (clearStateTimer) clearTimeout(clearStateTimer)
  clearStateTimer = setTimeout(() => {
    saveStateText.value = ''
    saveError.value = false
    clearStateTimer = null
  }, 1700)
}

async function persistSettings() {
  try {
    await lua.extensions.load('ui_phone_layout')
    const saved = await lua.ui_phone_layout?.updateSettings?.(getPhoneSettingsSnapshot())
    if (saved === false) throw new Error('Lua save returned false')
    setSaveState('Saved')
  } catch (e) {
    console.warn('Failed to save phone settings', e)
    setSaveState('Save failed', true)
  }
}

function queueSave() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    saveTimer = null
    persistSettings()
  }, 180)
}

function setPhoneSize(value) {
  if (phoneSettings.phoneSize === value) return
  setPhoneSettings({ phoneSize: value })
  queueSave()
}

function setBackgroundColor(value) {
  if (phoneSettings.backgroundColor === value) return
  setPhoneSettings({ backgroundColor: value })
  queueSave()
}

function applyBackgroundImage() {
  const next = (backgroundImageInput.value || '').trim()
  if (phoneSettings.backgroundImage === next) return
  setPhoneSettings({ backgroundImage: next })
  queueSave()
}

function clearBackgroundImage() {
  if (!phoneSettings.backgroundImage) return
  backgroundImageInput.value = ''
  setPhoneSettings({ backgroundImage: '' })
  queueSave()
}

function resetDefaults() {
  resetPhoneSettings()
  queueSave()
}

onMounted(async () => {
  try {
    await lua.extensions.load('ui_phone_layout')
    const fromLua = await lua.ui_phone_layout?.getSettings?.()
    if (fromLua) {
      replacePhoneSettings(fromLua)
      backgroundImageInput.value = fromLua.backgroundImage || ''
    }
  } catch (e) {
    console.warn('Failed to load phone settings', e)
  }
})

onUnmounted(() => {
  if (saveTimer) {
    clearTimeout(saveTimer)
    saveTimer = null
    persistSettings()
  }
  if (clearStateTimer) {
    clearTimeout(clearStateTimer)
    clearStateTimer = null
  }
})
</script>

<style scoped lang="scss">
.phone-settings {
  height: 100%;
  padding: 52px 14px 16px;
  display: flex;
  justify-content: center;
}

.settings-card {
  width: 100%;
  background: rgba(8, 8, 8, 0.72);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 16px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.setting-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.setting-label {
  color: rgba(255, 255, 255, 0.88);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.02em;
}

.option-row {
  display: flex;
  gap: 8px;
}

.picture-input {
  width: 100%;
  border: 1px solid rgba(255, 255, 255, 0.22);
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.92);
  border-radius: 10px;
  padding: 8px 10px;
  font-size: 12px;
  outline: none;
}

.picture-actions {
  display: flex;
  gap: 8px;
}

.option-button {
  flex: 1;
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.9);
  font-size: 12px;
  font-weight: 600;
  border-radius: 10px;
  padding: 8px 10px;
  cursor: pointer;
  transition: background 0.12s ease, border-color 0.12s ease;

  &.active {
    background: rgba(37, 99, 235, 0.35);
    border-color: rgba(96, 165, 250, 0.9);
  }
}

.color-row {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.color-swatch {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  border: 1px solid rgba(255, 255, 255, 0.4);
  cursor: pointer;
  position: relative;

  &.active::after {
    content: '';
    position: absolute;
    inset: 6px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.9);
  }
}

.custom-color {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.72);

  input {
    width: 26px;
    height: 22px;
    border: 0;
    background: transparent;
    padding: 0;
    cursor: pointer;
  }
}

.settings-footer {
  margin-top: auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}

.reset-button {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.92);
  font-size: 12px;
  font-weight: 600;
  border-radius: 10px;
  padding: 8px 12px;
  cursor: pointer;
}

.save-state {
  font-size: 11px;
  color: rgba(34, 197, 94, 0.95);

  &.error {
    color: rgba(239, 68, 68, 0.95);
  }
}
</style>
