import { reactive } from 'vue'

const SCALE_MIN = 0.5
const SCALE_MAX = 2
const SCALE_STEP = 0.1

export const NOTIFICATION_DISPLAY_MIN = 2
export const NOTIFICATION_DISPLAY_MAX = 15
export const NOTIFICATION_DISPLAY_DEFAULT = 8

export const DND_DURATION_OPTIONS = Object.freeze([
  { value: 0, label: 'Until turned off' },
  { value: 60, label: '1 hour' },
  { value: 120, label: '2 hours' },
  { value: 240, label: '4 hours' },
])

export const DEFAULT_PHONE_SETTINGS = Object.freeze({
  phoneSize: 1,
  horizontalPosition: 1,
  backgroundColor: '#1509fb',
  backgroundImage: '',
  notifications: {},
  doNotDisturb: false,
  doNotDisturbDurationMinutes: 0,
  doNotDisturbUntil: null,
  lockScreenNotificationsEnabled: true,
  lockScreenContentMode: 'show',
  lockScreenDisplaySeconds: NOTIFICATION_DISPLAY_DEFAULT,
  bannerNotificationsEnabled: true,
  bannerDisplaySeconds: NOTIFICATION_DISPLAY_DEFAULT,
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

const phoneSettings = reactive(normalizePhoneSettings({}))

export { phoneSettings }

function normalizeHexColor(value) {
  if (typeof value !== 'string') return DEFAULT_PHONE_SETTINGS.backgroundColor
  const trimmed = value.trim()
  if (!HEX_COLOR_PATTERN.test(trimmed)) return DEFAULT_PHONE_SETTINGS.backgroundColor
  return trimmed.toLowerCase()
}

function normalizeNotifications(value) {
  const out = {}
  if (value && typeof value === 'object') {
    for (const [key, enabled] of Object.entries(value)) {
      if (typeof key === 'string' && key) out[key] = enabled !== false
    }
  }
  return out
}

export function clampNotificationDisplaySeconds(value) {
  const n = Number(value)
  if (Number.isNaN(n)) return NOTIFICATION_DISPLAY_DEFAULT
  return Math.max(NOTIFICATION_DISPLAY_MIN, Math.min(NOTIFICATION_DISPLAY_MAX, Math.round(n)))
}

function normalizeLockScreenContentMode(value) {
  return value === 'hide' ? 'hide' : 'show'
}

function normalizeDndDurationMinutes(value) {
  const n = Number(value)
  if (Number.isNaN(n) || n < 0) return 0
  const allowed = DND_DURATION_OPTIONS.map(o => o.value)
  return allowed.includes(n) ? n : 0
}

function normalizeDndUntil(value) {
  if (value == null || value === '') return null
  const n = Number(value)
  if (Number.isNaN(n) || n <= 0) return null
  return Math.floor(n)
}

function migrateLegacyNotificationSettings(src) {
  const out = { ...src }
  const legacySeconds = src.notificationDisplaySeconds

  if (out.doNotDisturb === undefined && src.notificationsEnabled === false) {
    out.doNotDisturb = true
  }
  if (out.lockScreenContentMode === undefined && src.notificationsSimple === true) {
    out.lockScreenContentMode = 'hide'
  }
  if (out.lockScreenDisplaySeconds === undefined) {
    out.lockScreenDisplaySeconds = legacySeconds ?? NOTIFICATION_DISPLAY_DEFAULT
  }
  if (out.bannerDisplaySeconds === undefined) {
    out.bannerDisplaySeconds = legacySeconds ?? NOTIFICATION_DISPLAY_DEFAULT
  }
  if (out.doNotDisturb === undefined) {
    out.doNotDisturb = false
  }
  if (out.lockScreenNotificationsEnabled === undefined) {
    out.lockScreenNotificationsEnabled = true
  }
  if (out.bannerNotificationsEnabled === undefined) {
    out.bannerNotificationsEnabled = true
  }
  if (out.doNotDisturbDurationMinutes === undefined) {
    out.doNotDisturbDurationMinutes = 0
  }
  if (out.lockScreenContentMode === undefined) {
    out.lockScreenContentMode = 'show'
  }
  return out
}

export function getUnixNowSeconds() {
  return Math.floor(Date.now() / 1000)
}

export function isDoNotDisturbActive(settings = phoneSettings) {
  if (settings?.doNotDisturb !== true) return false
  const until = normalizeDndUntil(settings.doNotDisturbUntil)
  if (until == null) return true
  return getUnixNowSeconds() < until
}

export function resolveDoNotDisturbUntil(durationMinutes) {
  const minutes = normalizeDndDurationMinutes(durationMinutes)
  if (minutes <= 0) return null
  return getUnixNowSeconds() + minutes * 60
}

export function getLockScreenDisplayMs(settings = phoneSettings) {
  const seconds = clampNotificationDisplaySeconds(settings?.lockScreenDisplaySeconds)
  return Math.max(1800, seconds * 1000)
}

export function getBannerDisplayMs(settings = phoneSettings) {
  const seconds = clampNotificationDisplaySeconds(settings?.bannerDisplaySeconds)
  return Math.max(1800, seconds * 1000)
}

export function isLockScreenContentHidden(settings = phoneSettings) {
  return normalizeLockScreenContentMode(settings?.lockScreenContentMode) === 'hide'
}

/** @deprecated use getLockScreenDisplayMs / getBannerDisplayMs */
export function getNotificationDisplayMs(settings = phoneSettings) {
  return getBannerDisplayMs(settings)
}

/** @deprecated use isLockScreenContentHidden */
export function isNotificationsSimple(settings = phoneSettings) {
  return isLockScreenContentHidden(settings)
}

export function normalizePhoneSettings(value) {
  const src = migrateLegacyNotificationSettings(value && typeof value === 'object' ? value : {})
  const phoneSize = clampScale(src.phoneSize)
  const horizontalPosition = clampPosition(src.horizontalPosition)
  const backgroundColor = normalizeHexColor(src.backgroundColor)
  const backgroundImage = typeof src.backgroundImage === 'string' ? src.backgroundImage.trim() : ''
  const notifications = normalizeNotifications(src.notifications)
  const doNotDisturb = src.doNotDisturb === true
  const doNotDisturbDurationMinutes = normalizeDndDurationMinutes(src.doNotDisturbDurationMinutes)
  const doNotDisturbUntil = normalizeDndUntil(src.doNotDisturbUntil)
  const lockScreenNotificationsEnabled = src.lockScreenNotificationsEnabled !== false
  const lockScreenContentMode = normalizeLockScreenContentMode(src.lockScreenContentMode)
  const lockScreenDisplaySeconds = clampNotificationDisplaySeconds(src.lockScreenDisplaySeconds)
  const bannerNotificationsEnabled = src.bannerNotificationsEnabled !== false
  const bannerDisplaySeconds = clampNotificationDisplaySeconds(src.bannerDisplaySeconds)

  let resolvedDnd = doNotDisturb
  let resolvedUntil = doNotDisturbUntil
  if (resolvedDnd && resolvedUntil != null && getUnixNowSeconds() >= resolvedUntil) {
    resolvedDnd = false
    resolvedUntil = null
  }

  return {
    phoneSize,
    horizontalPosition,
    backgroundColor,
    backgroundImage,
    notifications,
    doNotDisturb: resolvedDnd,
    doNotDisturbDurationMinutes,
    doNotDisturbUntil: resolvedUntil,
    lockScreenNotificationsEnabled,
    lockScreenContentMode,
    lockScreenDisplaySeconds,
    bannerNotificationsEnabled,
    bannerDisplaySeconds,
  }
}

export function getPhoneSettingsSnapshot() {
  return normalizePhoneSettings(phoneSettings)
}

export function replacePhoneSettings(nextSettings) {
  Object.assign(phoneSettings, normalizePhoneSettings(nextSettings))
}

export function setPhoneSettings(patch) {
  const merged = normalizePhoneSettings({ ...getPhoneSettingsSnapshot(), ...(patch || {}) })
  Object.assign(phoneSettings, merged)
}

export function resetPhoneSettings() {
  Object.assign(phoneSettings, normalizePhoneSettings({}))
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
