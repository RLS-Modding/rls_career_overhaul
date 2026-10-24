import { computed, nextTick, ref, watch } from 'vue'
import { getBannerDisplayMs, phoneSettings } from './usePhoneSettings'

export const PHONE_HEADS_UP_DISPLAY_MS = 8000
const MAX_QUEUE_SIZE = 8

const queue = ref([])
const visible = ref(false)
let nextId = 1
let dismissTimer = null

function clearDismissTimer() {
  if (dismissTimer) {
    window.clearTimeout(dismissTimer)
    dismissTimer = null
  }
}

function resolveDismissMs(item) {
  if (item?.forceTtl && item.ttl > 0) {
    return Math.max(1800, item.ttl * 1000)
  }
  return getBannerDisplayMs()
}

function scheduleDismiss() {
  clearDismissTimer()
  const item = queue.value[0]
  dismissTimer = window.setTimeout(() => {
    dismissTimer = null
    visible.value = false
  }, resolveDismissMs(item))
}

watch(() => phoneSettings.bannerDisplaySeconds, () => {
  if (visible.value && !queue.value[0]?.forceTtl) {
    scheduleDismiss()
  }
})

function showCurrent() {
  if (!queue.value.length) {
    visible.value = false
    return
  }
  visible.value = true
  scheduleDismiss()
}

export function usePhoneHeadsUpNotification() {
  const current = computed(() => queue.value[0] ?? null)
  const extraCount = computed(() => Math.max(0, queue.value.length - 1))

  return {
    visible,
    current,
    extraCount,
  }
}

/** @param {ReturnType<typeof import('../utils/phoneNotificationPayload').normalizePhoneNotificationPayload>} payload */
export function pushHeadsUpNotification(payload) {
  if (!payload) return

  if (payload.replaceKey) {
    const existingIdx = queue.value.findIndex(item => item.replaceKey === payload.replaceKey)
    if (existingIdx !== -1) {
      const existing = queue.value[existingIdx]
      queue.value[existingIdx] = { ...existing, ...payload, id: existing.id }
      if (existingIdx === 0 && visible.value) {
        scheduleDismiss()
      }
      return { replaced: true, playSound: payload.sound !== false && payload.sound !== 'none' }
    }
  }

  queue.value.push({ ...payload, id: nextId++ })
  if (queue.value.length > MAX_QUEUE_SIZE) {
    queue.value = queue.value.slice(-MAX_QUEUE_SIZE)
  }

  if (queue.value.length === 1) {
    showCurrent()
  }
  return { replaced: false, playSound: true }
}

export function onPhoneHeadsUpAfterLeave() {
  if (queue.value.length) {
    queue.value.shift()
  }
  if (queue.value.length) {
    nextTick(() => showCurrent())
  }
}

export function dismissCurrentHeadsUp() {
  clearDismissTimer()
  if (!queue.value.length) {
    visible.value = false
    return
  }
  visible.value = false
}

export function clearPhoneHeadsUpNotifications() {
  clearDismissTimer()
  queue.value = []
  visible.value = false
}
