<template>
  <PhoneWrapper app-name="Settings">
    <div class="phone-settings" :style="accentStyle">
      <section class="settings-hero">
        <div class="hero-copy">
          <h2 class="hero-title">Phone Display</h2>
        </div>

        <div class="hero-preview">
          <div class="preview-device">
            <div class="preview-screen" :style="previewScreenStyle">
              <div class="preview-shade"></div>
              <div class="preview-topline">
                <span>{{ selectedPhoneSizeLabel }}</span>
                <span>{{ wallpaperModeLabel }}</span>
              </div>
              <div class="preview-stack">
                <div class="preview-card primary">
                  <span class="preview-label">Wallpaper</span>
                  <strong>{{ previewWallpaperLabel }}</strong>
                </div>
                <div class="preview-card secondary">
                  <span class="preview-label">Accent</span>
                  <div class="preview-accent-row">
                    <span class="preview-color-dot" :style="{ backgroundColor: phoneSettings.backgroundColor }"></span>
                    <strong>{{ selectedColorName }}</strong>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <div class="settings-card">
        <details class="settings-dropdown" open>
          <summary class="dropdown-summary">
            <div class="summary-copy">
              <span class="dropdown-title">Phone Size</span>
            </div>
            <div class="summary-meta-wrap">
              <span class="dropdown-meta">{{ selectedPhoneSizeLabel }}</span>
            </div>
          </summary>
          <div class="dropdown-content">
            <div class="option-row option-row-size">
              <button
                v-for="option in PHONE_SIZE_OPTIONS"
                :key="option.value"
                class="option-button option-card"
                :class="{ active: phoneSettings.phoneSize === option.value }"
                @click="setPhoneSize(option.value)"
              >
                <span class="option-title">{{ option.label }}</span>
              </button>
            </div>
          </div>
        </details>

        <details class="settings-dropdown">
          <summary class="dropdown-summary">
            <div class="summary-copy">
              <span class="dropdown-title">Wallpaper Image</span>
            </div>
            <div class="summary-meta-wrap">
              <span class="dropdown-meta">{{ wallpaperSelectionLabel }}</span>
            </div>
          </summary>
          <div class="dropdown-content">
            <div class="setting-row">
              <div class="setting-label">Wallpaper Folder</div>
              <div class="setting-actions">
                <button class="small-action" @click="openFolderInExplorer">Open Folder</button>
                <button class="small-action" @click="loadFolderImages">Refresh</button>
              </div>
            </div>
            <div class="folder-hint setting-surface">
              <span class="surface-label">Folder</span>
              <code>{{ folderPath }}</code>
            </div>
            <div class="wallpaper-hint setting-surface">
              Suggested wallpaper aspect ratio: <strong>{{ wallpaperAspectRatioLabel }}</strong>
              <span class="wallpaper-hint-muted">(portrait)</span>
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
              <span class="empty-folder-title">No wallpapers found</span>
              <span>Add `.png`, `.jpg`, `.jpeg`, or `.webp` images to the folder and refresh.</span>
            </div>
            <div class="picture-actions">
              <button class="option-button ghost-button" @click="clearBackgroundImage">Use Color Instead</button>
            </div>
          </div>
        </details>

        <details class="settings-dropdown">
          <summary class="dropdown-summary">
            <div class="summary-copy">
              <span class="dropdown-title">Background Color</span>
            </div>
            <div class="summary-meta-wrap">
              <span class="summary-color" :style="{ backgroundColor: phoneSettings.backgroundColor }"></span>
              <span class="dropdown-meta">{{ selectedColorName }}</span>
            </div>
          </summary>
          <div class="dropdown-content">
            <div class="color-preview setting-surface">
              <span class="surface-label">Selected Color</span>
              <div class="color-preview-chip">
                <span class="summary-color large" :style="{ backgroundColor: phoneSettings.backgroundColor }"></span>
                <strong>{{ selectedColorName }}</strong>
              </div>
            </div>
            <div class="color-row">
              <button
                v-for="color in PHONE_BACKGROUND_OPTIONS"
                :key="color.value"
                class="color-swatch"
                :class="{ active: phoneSettings.backgroundColor === color.value }"
                :style="{ backgroundColor: color.value }"
                @click="setBackgroundColor(color.value)"
                :title="color.name"
              ></button>
            </div>
          </div>
        </details>

        <div class="settings-footer">
          <button class="reset-button" @click="resetDefaults">Reset Defaults</button>
          <span v-if="saveStateText" class="save-state" :class="{ error: saveError }">{{ saveStateText }}</span>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, ref, onMounted, onUnmounted } from 'vue'
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
const folderPath = ref('/Phone/Backgrounds/')
const wallpaperAspectRatioLabel = '9:16'

let saveTimer = null
let clearStateTimer = null

function hexToRgba(hex, alpha) {
  const normalized = String(hex || '').replace('#', '')
  if (normalized.length !== 6) return `rgba(21, 9, 251, ${alpha})`

  const r = Number.parseInt(normalized.slice(0, 2), 16)
  const g = Number.parseInt(normalized.slice(2, 4), 16)
  const b = Number.parseInt(normalized.slice(4, 6), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

const accentStyle = computed(() => ({
  '--accent-color': phoneSettings.backgroundColor,
  '--accent-faint': hexToRgba(phoneSettings.backgroundColor, 0.12),
  '--accent-soft': hexToRgba(phoneSettings.backgroundColor, 0.22),
  '--accent-strong': hexToRgba(phoneSettings.backgroundColor, 0.34),
  '--accent-border': hexToRgba(phoneSettings.backgroundColor, 0.66),
}))

const previewScreenStyle = computed(() => {
  if (phoneSettings.backgroundImage) {
    return {
      backgroundImage: `linear-gradient(180deg, rgba(15, 23, 42, 0.18), rgba(2, 6, 23, 0.5)), url("${phoneSettings.backgroundImage}")`,
      backgroundSize: 'cover',
      backgroundPosition: 'center',
    }
  }

  return {
    backgroundImage: `radial-gradient(circle at top, rgba(255, 255, 255, 0.24), rgba(255, 255, 255, 0) 34%), linear-gradient(180deg, ${phoneSettings.backgroundColor} 0%, #05070c 100%)`,
  }
})

const selectedPhoneSizeLabel = computed(() => {
  const selected = PHONE_SIZE_OPTIONS.find(option => option.value === phoneSettings.phoneSize)
  return selected?.label || phoneSettings.phoneSize
})

const wallpaperSelectionLabel = computed(() => {
  return phoneSettings.backgroundImage ? 'Image' : 'Color'
})

const wallpaperModeLabel = computed(() => {
  return phoneSettings.backgroundImage ? 'Image' : 'Color'
})

const selectedColorName = computed(() => {
  const found = PHONE_BACKGROUND_OPTIONS.find(c => c.value === phoneSettings.backgroundColor)
  return found?.name ?? String(phoneSettings.backgroundColor || '').toUpperCase()
})

const previewWallpaperLabel = computed(() => {
  return phoneSettings.backgroundImage ? 'Custom image' : 'Color only'
})

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
:deep(.phone-content) {
  background:
    radial-gradient(circle at top, rgba(63, 63, 70, 0.28), rgba(0, 0, 0, 0) 32%),
    linear-gradient(180deg, #09090b 0%, #020617 100%);
}

.phone-settings {
  height: 100%;
  padding: 52px 14px 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  overflow-y: auto;
  overflow-x: hidden;

  &::-webkit-scrollbar {
    width: 7px;
  }

  &::-webkit-scrollbar-track {
    background: transparent;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.16);
    border-radius: 999px;
  }
}

.settings-hero {
  position: relative;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 12px;
  padding: 14px;
  border-radius: 20px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background:
    linear-gradient(135deg, rgba(255, 255, 255, 0.08), rgba(255, 255, 255, 0.02)),
    radial-gradient(circle at top right, var(--accent-strong), transparent 42%);
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.06),
    0 14px 24px rgba(0, 0, 0, 0.28);
}

.hero-copy {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0;
  min-width: 0;
}

.hero-title {
  margin: 0;
  color: #f8fafc;
  font-size: 19px;
  line-height: 1.1;
  font-weight: 800;
}

.hero-preview {
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.preview-device {
  padding: 6px;
  border-radius: 20px;
  background: linear-gradient(180deg, rgba(39, 39, 42, 0.92), rgba(9, 9, 11, 0.96));
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.08),
    0 8px 20px rgba(0, 0, 0, 0.35);
}

.preview-screen {
  position: relative;
  width: 108px;
  height: 168px;
  border-radius: 16px;
  overflow: hidden;
  padding: 10px;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.preview-shade {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, rgba(2, 6, 23, 0.04), rgba(2, 6, 23, 0.42));
}

.preview-topline,
.preview-stack {
  position: relative;
  z-index: 1;
}

.preview-topline {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  color: rgba(255, 255, 255, 0.86);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.preview-stack {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.preview-card {
  padding: 9px;
  border-radius: 12px;
  backdrop-filter: blur(10px);
  background: rgba(2, 6, 23, 0.42);
  border: 1px solid rgba(255, 255, 255, 0.08);
  box-shadow: 0 8px 16px rgba(0, 0, 0, 0.22);

  strong {
    display: block;
    color: #f8fafc;
    font-size: 10px;
    line-height: 1.25;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
}

.preview-card.secondary {
  background: rgba(2, 6, 23, 0.32);
}

.preview-label {
  display: block;
  margin-bottom: 4px;
  color: rgba(226, 232, 240, 0.66);
  font-size: 7px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.preview-accent-row {
  display: flex;
  align-items: center;
  gap: 6px;
}

.preview-color-dot {
  width: 10px;
  height: 10px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.45);
  box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.08);
}

.settings-card {
  width: 100%;
  background: rgba(8, 8, 8, 0.58);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 20px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.04),
    0 12px 28px rgba(0, 0, 0, 0.28);
}

.settings-dropdown {
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 16px;
  background: linear-gradient(180deg, rgba(255, 255, 255, 0.045), rgba(255, 255, 255, 0.03));
  overflow: hidden;
  transition: border-color 0.18s ease, background 0.18s ease, box-shadow 0.18s ease;

  &[open] {
    border-color: rgba(255, 255, 255, 0.16);
    background:
      linear-gradient(180deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0.04)),
      linear-gradient(135deg, var(--accent-faint), transparent 50%);
    box-shadow:
      inset 0 0 0 1px rgba(255, 255, 255, 0.04),
      0 10px 20px rgba(0, 0, 0, 0.18);
  }
}

.dropdown-summary {
  list-style: none;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px 14px;
  color: rgba(255, 255, 255, 0.9);
  user-select: none;

  &::-webkit-details-marker {
    display: none;
  }

  &::after {
    content: '';
    width: 8px;
    height: 8px;
    border-right: 2px solid rgba(255, 255, 255, 0.68);
    border-bottom: 2px solid rgba(255, 255, 255, 0.68);
    transform: rotate(45deg);
    margin-left: 4px;
    transition: transform 0.16s ease;
  }
}

.settings-dropdown[open] .dropdown-summary::after {
  transform: rotate(-135deg) translateY(-1px);
}

.summary-copy {
  display: flex;
  flex-direction: column;
  gap: 0;
  min-width: 0;
}

.dropdown-title {
  font-size: 13px;
  font-weight: 700;
  color: #f8fafc;
}

.summary-meta-wrap {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 8px;
  flex: none;
}

.dropdown-meta {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.76);
  font-weight: 700;
  white-space: nowrap;
}

.summary-color {
  width: 14px;
  height: 14px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.45);
  box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.06);
}

.summary-color.large {
  width: 22px;
  height: 22px;
}

.dropdown-content {
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding: 12px 14px 14px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  animation: dropdown-content-in 0.16s ease;
}

.setting-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}

.setting-actions {
  display: flex;
  gap: 6px;
}

.setting-label {
  color: rgba(255, 255, 255, 0.9);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.02em;
}

.setting-surface {
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.04);
  padding: 10px 11px;
}

.surface-label {
  display: block;
  margin-bottom: 4px;
  color: rgba(226, 232, 240, 0.54);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
}

.small-action {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.07);
  color: rgba(255, 255, 255, 0.9);
  border-radius: 10px;
  padding: 6px 9px;
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
  transition: border-color 0.14s ease, background 0.14s ease;

  &:hover {
    border-color: rgba(255, 255, 255, 0.32);
    background: rgba(255, 255, 255, 0.1);
  }
}

.folder-hint {
  color: rgba(255, 255, 255, 0.65);
  font-size: 11px;
  line-height: 1.45;

  code {
    display: block;
    color: rgba(255, 255, 255, 0.95);
    word-break: break-all;
  }
}

.wallpaper-hint {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.84);
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  align-items: center;

  strong {
    color: rgba(255, 255, 255, 0.98);
  }
}

.wallpaper-hint-muted {
  color: rgba(255, 255, 255, 0.64);
}

.option-row {
  display: flex;
  gap: 8px;
}

.option-row-size {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
}

.picture-actions {
  display: flex;
  gap: 8px;
}

.option-button {
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.9);
  font-size: 12px;
  font-weight: 600;
  border-radius: 12px;
  padding: 10px 12px;
  cursor: pointer;
  transition: background 0.12s ease, border-color 0.12s ease, transform 0.12s ease;

  &.active {
    background: var(--accent-soft);
    border-color: var(--accent-border);
    box-shadow: 0 8px 18px rgba(0, 0, 0, 0.18);
  }

  &:hover {
    transform: translateY(-1px);
  }
}

.option-card {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
  min-width: 0;
}

.option-title {
  color: #f8fafc;
  font-size: 12px;
  font-weight: 700;
}

.ghost-button {
  width: 100%;
  justify-content: center;
  background: rgba(255, 255, 255, 0.04);
}

.image-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
  max-height: 206px;
  overflow-y: auto;
  padding-right: 2px;
}

.image-tile {
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.05);
  border-radius: 12px;
  overflow: hidden;
  cursor: pointer;
  padding: 0;
  text-align: left;
  transition: transform 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease;

  &.active {
    border-color: var(--accent-border);
    box-shadow:
      0 0 0 1px var(--accent-soft) inset,
      0 10px 20px rgba(0, 0, 0, 0.18);
  }

  &:hover {
    transform: translateY(-1px);
  }

  img {
    width: 100%;
    height: 72px;
    object-fit: cover;
    display: block;
    background: rgba(0, 0, 0, 0.2);
  }

  span {
    display: block;
    font-size: 10px;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.85);
    padding: 7px 8px 8px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
}

.empty-folder {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.68);
  border: 1px dashed rgba(255, 255, 255, 0.16);
  border-radius: 12px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  line-height: 1.45;
}

.empty-folder-title {
  color: #f8fafc;
  font-weight: 700;
}

.color-row {
  display: grid;
  grid-template-columns: repeat(6, minmax(0, 1fr));
  gap: 8px;
}

.color-preview {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}

.color-preview-chip {
  display: flex;
  align-items: center;
  gap: 8px;

  strong {
    color: #f8fafc;
    font-size: 12px;
  }
}

.color-swatch {
  width: 100%;
  aspect-ratio: 1;
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.4);
  cursor: pointer;
  position: relative;
  transition: transform 0.12s ease, box-shadow 0.12s ease, border-color 0.12s ease;

  &:hover {
    transform: translateY(-1px);
  }

  &.active::after {
    content: '';
    position: absolute;
    inset: 6px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.9);
  }

  &.active {
    box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.35), 0 6px 16px rgba(0, 0, 0, 0.24);
  }
}

.settings-footer {
  margin-top: auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding-top: 2px;
}

.reset-button {
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.07);
  color: rgba(255, 255, 255, 0.92);
  font-size: 12px;
  font-weight: 600;
  border-radius: 999px;
  padding: 10px 14px;
  cursor: pointer;
  transition: background 0.12s ease, border-color 0.12s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.12);
    border-color: rgba(255, 255, 255, 0.26);
  }
}

.save-state {
  font-size: 11px;
  font-weight: 700;
  color: rgba(52, 211, 153, 0.98);
  padding: 7px 10px;
  border-radius: 999px;
  background: rgba(6, 78, 59, 0.42);
  border: 1px solid rgba(52, 211, 153, 0.28);

  &.error {
    color: rgba(254, 202, 202, 0.98);
    background: rgba(127, 29, 29, 0.44);
    border-color: rgba(248, 113, 113, 0.28);
  }
}

@keyframes dropdown-content-in {
  from {
    opacity: 0;
    transform: translateY(-3px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

@media (max-width: 340px) {
  .settings-hero {
    grid-template-columns: 1fr;
  }

  .hero-preview {
    justify-content: flex-start;
  }
}
</style>
