import { reactive } from 'vue'

export const DEFAULT_PHONE_SETTINGS = Object.freeze({
  phoneSize: 'normal',
  backgroundColor: '#1509fb',
  backgroundImage: '',
})

export const PHONE_SIZE_OPTIONS = Object.freeze([
  { value: 'small', label: 'Small' },
  { value: 'normal', label: 'Normal' },
  { value: 'large', label: 'Large' },
])

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

const PHONE_SIZE_SCALE = Object.freeze({
  small: 0.72,
  normal: 0.8,
  large: 0.9,
})

const PHONE_SETTINGS_SESSION_KEY = 'phone_settings'
const HEX_COLOR_PATTERN = /^#[0-9a-fA-F]{6}$/

const phoneSettings = reactive({ ...DEFAULT_PHONE_SETTINGS })
let hydrated = false

function normalizeHexColor(value) {
  if (typeof value !== 'string') return DEFAULT_PHONE_SETTINGS.backgroundColor
  const trimmed = value.trim()
  if (!HEX_COLOR_PATTERN.test(trimmed)) return DEFAULT_PHONE_SETTINGS.backgroundColor
  return trimmed.toLowerCase()
}

export function normalizePhoneSettings(value) {
  const src = value && typeof value === 'object' ? value : {}

  const phoneSize = PHONE_SIZE_SCALE[src.phoneSize] ? src.phoneSize : DEFAULT_PHONE_SETTINGS.phoneSize
  const backgroundColor = normalizeHexColor(src.backgroundColor)
  const backgroundImage = typeof src.backgroundImage === 'string' ? src.backgroundImage.trim() : ''

  return { phoneSize, backgroundColor, backgroundImage }
}

function persistToSession() {
  try {
    sessionStorage.setItem(PHONE_SETTINGS_SESSION_KEY, JSON.stringify(getPhoneSettingsSnapshot()))
  } catch (_) {
    // Ignore storage failures.
  }
}

function hydrateFromSession() {
  if (hydrated) return
  hydrated = true
  try {
    const raw = sessionStorage.getItem(PHONE_SETTINGS_SESSION_KEY)
    if (!raw) return
    const parsed = JSON.parse(raw)
    Object.assign(phoneSettings, normalizePhoneSettings(parsed))
  } catch (_) {
    // Ignore malformed persisted data.
  }
}

export function getPhoneSettingsSnapshot() {
  return {
    phoneSize: phoneSettings.phoneSize,
    backgroundColor: phoneSettings.backgroundColor,
    backgroundImage: phoneSettings.backgroundImage,
  }
}

export function replacePhoneSettings(nextSettings) {
  Object.assign(phoneSettings, normalizePhoneSettings(nextSettings))
  persistToSession()
}

export function setPhoneSettings(patch) {
  const merged = normalizePhoneSettings({ ...getPhoneSettingsSnapshot(), ...(patch || {}) })
  Object.assign(phoneSettings, merged)
  persistToSession()
}

export function resetPhoneSettings() {
  Object.assign(phoneSettings, DEFAULT_PHONE_SETTINGS)
  persistToSession()
}

export function getPhoneScale(settings = phoneSettings) {
  const normalized = normalizePhoneSettings(settings)
  return PHONE_SIZE_SCALE[normalized.phoneSize] || PHONE_SIZE_SCALE.normal
}

export function usePhoneSettings() {
  hydrateFromSession()
  return {
    phoneSettings,
    setPhoneSettings,
    replacePhoneSettings,
    resetPhoneSettings,
    getPhoneSettingsSnapshot,
  }
}
