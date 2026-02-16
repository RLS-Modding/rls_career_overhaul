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
          <div class="setting-row">
            <div class="setting-label">Background Picture (Folder)</div>
            <div class="setting-actions">
              <button class="small-action" @click="openFolderInExplorer">Open Folder</button>
              <button class="small-action" @click="loadFolderImages">Refresh</button>
            </div>
          </div>
          <div class="folder-hint">
            Folder: <code>{{ folderPath }}</code>
          </div>
          <div class="image-grid" v-if="folderImages.length">
            <button
              v-for="entry in folderImages"
              :key="entry.path"
              class="image-tile"
              :class="{ active: phoneSettings.backgroundImage === entry.path }"
              @click="selectFolderImage(entry.path)"
              :title="entry.name"
            >
              <img :src="entry.path" :alt="entry.name" />
              <span>{{ entry.name }}</span>
            </button>
          </div>
          <div class="empty-folder" v-else>
            No images found in the folder yet.
          </div>
          <div class="picture-actions">
            <button class="option-button" @click="clearBackgroundImage">Use Color Instead</button>
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
const folderImages = ref([])
const folderPath = ref('/phone-backgrounds/')

let saveTimer = null
let clearStateTimer = null

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

function selectFolderImage(path) {
  if (phoneSettings.backgroundImage === path) return
  setPhoneSettings({ backgroundImage: path })
  queueSave()
}

function clearBackgroundImage() {
  if (!phoneSettings.backgroundImage) return
  setPhoneSettings({ backgroundImage: '' })
  queueSave()
}

function resetDefaults() {
  resetPhoneSettings()
  queueSave()
}

async function loadFolderImages() {
  try {
    await lua.extensions.load('ui_phone_layout')
    const folder = await lua.ui_phone_layout?.getBackgroundFolder?.()
    if (typeof folder === 'string' && folder.trim()) {
      folderPath.value = folder
    }
    const images = await lua.ui_phone_layout?.listBackgroundImages?.()
    folderImages.value = Array.isArray(images) ? images : []
  } catch (e) {
    console.warn('Failed to list phone background images', e)
    folderImages.value = []
  }
}

async function openFolderInExplorer() {
  try {
    await lua.extensions.load('ui_phone_layout')
    const ok = await lua.ui_phone_layout?.openBackgroundFolder?.()
    if (ok === false) {
      setSaveState('Could not open folder', true)
      return
    }
  } catch (e) {
    console.warn('Failed to open phone backgrounds folder', e)
    setSaveState('Could not open folder', true)
  }
}

onMounted(async () => {
  try {
    await lua.extensions.load('ui_phone_layout')
    const fromLua = await lua.ui_phone_layout?.getSettings?.()
    if (fromLua) {
      replacePhoneSettings(fromLua)
    }
  } catch (e) {
    console.warn('Failed to load phone settings', e)
  }

  await loadFolderImages()
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

.setting-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
}

.setting-actions {
  display: flex;
  gap: 6px;
}

.setting-label {
  color: rgba(255, 255, 255, 0.88);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.02em;
}

.small-action {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.9);
  border-radius: 8px;
  padding: 4px 8px;
  font-size: 11px;
  cursor: pointer;
}

.folder-hint {
  color: rgba(255, 255, 255, 0.65);
  font-size: 11px;

  code {
    color: rgba(255, 255, 255, 0.95);
  }
}

.option-row {
  display: flex;
  gap: 8px;
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

.image-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
  max-height: 170px;
  overflow-y: auto;
}

.image-tile {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.05);
  border-radius: 8px;
  overflow: hidden;
  cursor: pointer;
  padding: 0;
  text-align: left;

  &.active {
    border-color: rgba(96, 165, 250, 0.9);
    box-shadow: 0 0 0 1px rgba(96, 165, 250, 0.6) inset;
  }

  img {
    width: 100%;
    height: 58px;
    object-fit: cover;
    display: block;
    background: rgba(0, 0, 0, 0.2);
  }

  span {
    display: block;
    font-size: 10px;
    color: rgba(255, 255, 255, 0.85);
    padding: 4px 6px 6px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
}

.empty-folder {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.65);
  border: 1px dashed rgba(255, 255, 255, 0.2);
  border-radius: 8px;
  padding: 10px;
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
