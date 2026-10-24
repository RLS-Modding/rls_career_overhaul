<template>
  <Teleport to="body">
    <div class="scene-toast-app" aria-live="polite" aria-atomic="false">
      <TransitionGroup name="scene-toast" tag="div" class="scene-toast-list">
        <article
          v-for="toast in toasts"
          :key="toast.id"
          class="scene-toast"
          :class="`scene-toast--${toast.kind}`"
        >
          <div class="scene-toast__rail"></div>
          <div class="scene-toast__content">
            <div class="scene-toast__header">
              <span class="scene-toast__source">{{ toast.source }}</span>
              <span v-if="toast.meta" class="scene-toast__meta">{{ toast.meta }}</span>
            </div>
            <h3 class="scene-toast__title">{{ toast.title }}</h3>
            <p v-if="toast.message !== toast.title" class="scene-toast__message">{{ toast.message }}</p>
            <div v-if="toast.action" class="scene-toast__action">
              <BngBinding :action="toast.action" show-unassigned />
              <span>{{ toast.actionLabel }}</span>
            </div>
          </div>
        </article>
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { BngBinding } from "@/common/components/base"

const bridge = useBridge()
const toasts = ref([])
let nextId = 1

const normalizePayload = raw => {
  if (Array.isArray(raw)) {
    raw = raw.find(entry => entry && typeof entry === "object") || raw[0]
  }
  if (!raw || typeof raw !== "object") return null
  const message = String(raw.message || raw.msg || "").trim()
  if (!message) return null
  return {
    title: String(raw.title || "Car Scene").trim(),
    message,
    source: String(raw.source || "Car Meets").trim(),
    meta: raw.meta ? String(raw.meta).trim() : "",
    kind: ["success", "warning", "error", "invite", "rep", "racing", "dakar", "journal"].includes(raw.kind) ? raw.kind : "info",
    action: raw.action ? String(raw.action).trim() : "",
    actionLabel: String(raw.actionLabel || "Continue").trim(),
    dedupeKey: raw.dedupeKey ? String(raw.dedupeKey).trim() : "",
    ttl: Number(raw.ttl) > 0 ? Number(raw.ttl) * 2 : 10,
  }
}

const clearToastTimeout = toast => {
  if (toast?.timeoutId) {
    window.clearTimeout(toast.timeoutId)
    toast.timeoutId = undefined
  }
}

const dismissToast = id => {
  const idx = toasts.value.findIndex(item => item.id === id)
  if (idx === -1) return
  const [removed] = toasts.value.splice(idx, 1)
  clearToastTimeout(removed)
}

const clearAllToasts = () => {
  for (const item of toasts.value) clearToastTimeout(item)
  toasts.value = []
}

const pushToast = raw => {
  const payload = normalizePayload(raw)
  if (!payload) return

  const receivedAt = Date.now()
  const signature = [payload.source, payload.title, payload.message, payload.action].join("\u0000")
  if (toasts.value.some(item => item.signature === signature && receivedAt - item.receivedAt < 500)) return

  if (payload.dedupeKey) {
    const replaced = toasts.value.filter(item => item.dedupeKey === payload.dedupeKey)
    for (const item of replaced) clearToastTimeout(item)
    toasts.value = toasts.value.filter(item => item.dedupeKey !== payload.dedupeKey)
  }

  const toast = {
    ...payload,
    id: nextId++,
    receivedAt,
    signature,
  }
  const nextToasts = [toast, ...toasts.value].slice(0, 4)
  const nextIds = new Set(nextToasts.map(item => item.id))
  for (const item of toasts.value) {
    if (!nextIds.has(item.id)) clearToastTimeout(item)
  }
  toasts.value = nextToasts

  toast.timeoutId = window.setTimeout(
    () => dismissToast(toast.id),
    Math.max(1800, toast.ttl * 1000)
  )
}

onMounted(() => {
  bridge.events.on("CarMeetToast", pushToast)
  bridge.events.on("CarMeetToastClear", clearAllToasts)
})

onBeforeUnmount(() => {
  bridge.events.off("CarMeetToast", pushToast)
  bridge.events.off("CarMeetToastClear", clearAllToasts)
  clearAllToasts()
})
</script>

<style scoped lang="scss">
.scene-toast-app {
  // scaled unit: same share of the screen at 720p..4K (rem/px-sized it shrank at 1440p), still following
  // the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  position: fixed;
  top: max(calc(4.75 * var(--rls-u, 1rem)), env(safe-area-inset-top));
  right: max(calc(1.25 * var(--rls-u, 1rem)), env(safe-area-inset-right));
  z-index: 13040;
  width: min(calc(22 * var(--rls-u, 1rem)), calc(100vw - calc(2.5 * var(--rls-u, 1rem))));
  pointer-events: none;
  font-family: var(--fnt-defs, "Noto Sans", Arial, sans-serif);
}

/* Photo Mode adds this class while rendering a clean capture. The toast is
   teleported to body, so it needs a global ancestor selector to stay out of
   the saved screenshot. */
:global(.photomode-capture-active) .scene-toast-app {
  display: none !important;
}

.scene-toast-list {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: calc(0.55 * var(--rls-u, 1rem));
}

.scene-toast {
  position: relative;
  display: grid;
  grid-template-columns: calc(0.25 * var(--rls-u, 1rem)) 1fr;
  min-height: calc(4.8 * var(--rls-u, 1rem));
  width: 100%;
  overflow: hidden;
  border-radius: calc(0.5 * var(--rls-u, 1rem));
  color: #f4f0ea;
  background: linear-gradient(90deg, rgba(18, 19, 20, 0.95), rgba(33, 31, 28, 0.91));
  border: 1px solid rgba(255, 255, 255, 0.12);
  box-shadow: 0 calc(0.6 * var(--rls-u, 1rem)) calc(1.7 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.42);
  backdrop-filter: blur(calc(0.625 * var(--rls-u, 1rem)));
}

.scene-toast__rail {
  background: #f06d2f;
}

.scene-toast--success .scene-toast__rail,
.scene-toast--rep .scene-toast__rail {
  background: #69d48f;
}

.scene-toast--warning .scene-toast__rail,
.scene-toast--invite .scene-toast__rail {
  background: #f0b84a;
}

.scene-toast--dakar .scene-toast__rail {
  background: #e0703a;
}

.scene-toast--error .scene-toast__rail {
  background: #e15d5d;
}

.scene-toast--journal .scene-toast__rail {
  background: linear-gradient(180deg, #d898ad, #67b7ae);
}

.scene-toast__content {
  padding: calc(0.72 * var(--rls-u, 1rem)) calc(0.9 * var(--rls-u, 1rem)) calc(0.82 * var(--rls-u, 1rem));
}

.scene-toast__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.75 * var(--rls-u, 1rem));
  margin-bottom: calc(0.28 * var(--rls-u, 1rem));
  font-size: calc(0.68 * var(--rls-u, 1rem));
  line-height: 1;
  letter-spacing: 0;
  text-transform: uppercase;
  color: rgba(244, 240, 234, 0.62);
}

.scene-toast__source,
.scene-toast__meta {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.scene-toast__title {
  margin: 0;
  font-size: var(--rls-u, 1rem);
  line-height: 1.18;
  font-weight: 700;
  letter-spacing: 0;
  color: #fff8ef;
}

.scene-toast__message {
  margin: calc(0.28 * var(--rls-u, 1rem)) 0 0;
  font-size: calc(0.82 * var(--rls-u, 1rem));
  line-height: 1.32;
  color: rgba(244, 240, 234, 0.88);
}

.scene-toast--invite .scene-toast__message {
  font-weight: 800;
  color: #fff6e8;
}

.scene-toast__action {
  display: flex;
  align-items: center;
  gap: calc(0.42 * var(--rls-u, 1rem));
  margin-top: calc(0.5 * var(--rls-u, 1rem));
  font-size: calc(0.76 * var(--rls-u, 1rem));
  font-weight: 700;
  color: #f5dfbd;
}

.scene-toast-enter-active,
.scene-toast-leave-active {
  transition: opacity 0.18s ease, transform 0.18s ease;
}

.scene-toast-enter-from,
.scene-toast-leave-to {
  opacity: 0;
  transform: translateX(calc(0.75 * var(--rls-u, 1rem)));
}

.scene-toast-move {
  transition: transform 0.18s ease;
}
</style>
