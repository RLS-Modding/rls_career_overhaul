<template>
  <Teleport to="body">
    <div v-if="visible" class="rls-load-overlay" :class="{ 'rls-load-overlay--opaque': opaque }" role="status" aria-live="polite">
      <div class="rls-load-overlay__panel">
        <div class="rls-load-overlay__spinner" aria-hidden="true" />
        <p v-if="message" class="rls-load-overlay__msg">{{ message }}</p>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"

const bridge = useBridge()
const visible = ref(false)
const opaque = ref(false)
const message = ref("")

const normalizePayload = raw => {
  if (!raw || typeof raw !== "object") return {}
  if (Array.isArray(raw) && raw.length > 0 && raw[0] && typeof raw[0] === "object" && !Array.isArray(raw[0])) {
    return raw[0]
  }
  return raw
}

const onLoading = (...args) => {
  const d = normalizePayload(args.length > 0 ? args[0] : null)
  if (d.visible === true) {
    visible.value = true
    opaque.value = d.opaque === true
    message.value = typeof d.message === "string" ? d.message : ""
  } else {
    visible.value = false
    opaque.value = false
    message.value = ""
  }
}

onMounted(() => {
  bridge.events.on("rlsCareerLoadingOverlay", onLoading)
})

onBeforeUnmount(() => {
  bridge.events.off("rlsCareerLoadingOverlay", onLoading)
})
</script>

<style scoped lang="scss">
.rls-load-overlay {
  // scaled unit: same share of the screen at 720p..4K (rem/px-sized it shrank at 1440p), still following
  // the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  font-size: var(--rls-u, 1rem);
  position: fixed;
  inset: 0;
  z-index: 14000;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.45);
  pointer-events: auto;
}

.rls-load-overlay__panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(0.75 * var(--rls-u, 1rem));
  padding: calc(1.25 * var(--rls-u, 1rem)) calc(1.5 * var(--rls-u, 1rem));
  border-radius: calc(0.625 * var(--rls-u, 1rem));
  background: rgba(20, 22, 28, 0.92);
  box-shadow: 0 calc(0.5 * var(--rls-u, 1rem)) calc(2 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.35);
}

.rls-load-overlay--opaque {
  background: #14161c;
}

.rls-load-overlay__spinner {
  width: calc(2.25 * var(--rls-u, 1rem));
  height: calc(2.25 * var(--rls-u, 1rem));
  border: calc(0.1875 * var(--rls-u, 1rem)) solid rgba(255, 255, 255, 0.15);
  border-top-color: rgba(255, 255, 255, 0.85);
  border-radius: 50%;
  animation: rls-load-spin 0.75s linear infinite;
}

.rls-load-overlay__msg {
  margin: 0;
  font-size: calc(0.9 * var(--rls-u, 1rem));
  color: rgba(255, 255, 255, 0.88);
  text-align: center;
  max-width: calc(18 * var(--rls-u, 1rem));
}

@keyframes rls-load-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
