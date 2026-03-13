import { reactive } from 'vue'

const SCALE_MIN = 0.5
const SCALE_MAX = 2
const SCALE_STEP = 0.1

export const DEFAULT_PHONE_SETTINGS = Object.freeze({
  phoneSize: 1,
  horizontalPosition: 1,
  backgroundColor: '#1509fb',
  backgroundImage: '',
})

export const PHONE_SCALE_MIN = SCALE_MIN
export const PHONE_SCALE_MAX = SCALE_MAX
export const PHONE_SCALE_STEP = SCALE_STEP
export const PHONE_SCALE_BASE = 1

export const PHONE_BACKGROUND_OPTIONS = Object.freeze([
  { value: '#111827', name: 'Charcoal' },
  { value: '#374151', name: 'Gray' },
  { value: '#6b7280', name: 'Slate' },
  { value: '#9ca3af', name: 'Silver' },
  { value: '#e5e7eb', name: 'Off-white' },
  { value: '#ef4444', name: 'Red' },
  { value: '#f97316', name: 'Orange' },
  { value: '#f59e0b', name: 'Amber' },
  { value: '#eab308', name: 'Yellow' },
  { value: '#84cc16', name: 'Lime' },
  { value: '#22c55e', name: 'Green' },
  { value: '#1509fb', name: 'Blue' },
  { value: '#1d4ed8', name: 'Navy' },
  { value: '#2563eb', name: 'Sky' },
  { value: '#06b6d4', name: 'Cyan' },
  { value: '#14b8a6', name: 'Teal' },
  { value: '#059669', name: 'Emerald' },
  { value: '#6366f1', name: 'Indigo' },
  { value: '#a855f7', name: 'Purple' },
  { value: '#d946ef', name: 'Magenta' },
  { value: '#ec4899', name: 'Pink' },
  { value: '#be123c', name: 'Rose' },
  { value: '#6d28d9', name: 'Violet' },
])

function clampScale(value) {
  const n = Number(value)
  if (Number.isNaN(n)) return DEFAULT_PHONE_SETTINGS.phoneSize
  const stepped = Math.round(n / SCALE_STEP) * SCALE_STEP
  return Math.max(SCALE_MIN, Math.min(SCALE_MAX, stepped))
}

function clampPosition(value) {
  const n = Number(value)
  if (Number.isNaN(n)) return DEFAULT_PHONE_SETTINGS.horizontalPosition
  return Math.max(0, Math.min(1, n))
}

const HEX_COLOR_PATTERN = /^#[0-9a-fA-F]{6}$/

const phoneSettings = reactive({ ...DEFAULT_PHONE_SETTINGS })

function normalizeHexColor(value) {
  if (typeof value !== 'string') return DEFAULT_PHONE_SETTINGS.backgroundColor
  const trimmed = value.trim()
  if (!HEX_COLOR_PATTERN.test(trimmed)) return DEFAULT_PHONE_SETTINGS.backgroundColor
  return trimmed.toLowerCase()
}

export function normalizePhoneSettings(value) {
  const src = value && typeof value === 'object' ? value : {}
  const phoneSize = clampScale(src.phoneSize)
  const horizontalPosition = clampPosition(src.horizontalPosition)
  const backgroundColor = normalizeHexColor(src.backgroundColor)
  const backgroundImage = typeof src.backgroundImage === 'string' ? src.backgroundImage.trim() : ''
  return { phoneSize, horizontalPosition, backgroundColor, backgroundImage }
}

export function getPhoneSettingsSnapshot() {
  return {
    phoneSize: phoneSettings.phoneSize,
    horizontalPosition: phoneSettings.horizontalPosition,
    backgroundColor: phoneSettings.backgroundColor,
    backgroundImage: phoneSettings.backgroundImage,
  }
}

export function replacePhoneSettings(nextSettings) {
  Object.assign(phoneSettings, normalizePhoneSettings(nextSettings))
}

export function setPhoneSettings(patch) {
  const merged = normalizePhoneSettings({ ...getPhoneSettingsSnapshot(), ...(patch || {}) })
  Object.assign(phoneSettings, merged)
}

export function resetPhoneSettings() {
  Object.assign(phoneSettings, DEFAULT_PHONE_SETTINGS)
}

export function getPhoneScale(settings = phoneSettings) {
  const normalized = normalizePhoneSettings(settings)
  return normalized.phoneSize
}

export function getPhonePosition(settings = phoneSettings) {
  const normalized = normalizePhoneSettings(settings)
  return normalized.horizontalPosition
}

export function usePhoneSettings() {
  return {
    phoneSettings,
    setPhoneSettings,
    replacePhoneSettings,
    resetPhoneSettings,
    getPhoneSettingsSnapshot,
  }
}
