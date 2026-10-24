<template>
  <Teleport to="body">
    <div v-if="visible" class="rtp-team-load-overlay" aria-busy="true" aria-live="polite">
      <!-- Same image pipeline as stock LoadingScreen.vue (progress mode, vanilla drive art). -->
      <div class="rtp-team-load-overlay__bg" :style="bgStyle" />
      <div class="rtp-team-load-overlay__scrim" />
      <div class="rtp-team-load-overlay__content">
        <div class="rtp-team-load-overlay__panel">
          <div class="rtp-team-load-overlay__spinner" />
          <p v-if="message" class="rtp-team-load-overlay__msg">{{ message }}</p>
        </div>
      </div>
      <!-- Match LoadingScreen: keep image decoded in DOM -->
      <div v-if="backgroundUrl" class="rtp-team-load-overlay__cache" aria-hidden="true">
        <img :src="backgroundUrl" alt="" />
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { safeLua } from "../utils/safeLua.js"

import { ref, computed, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"
import { getAssetURL } from "@/utils"

const bridge = useBridge()
const visible = ref(false)
const message = ref("")
const backgroundUrl = ref(null)

const STOCK_LOADING_IMAGES_COUNT = 15

let lastStockImageNum = -1

const randomStockImageNum = () => {
  let n = ~~(Math.random() * STOCK_LOADING_IMAGES_COUNT) + 1
  if (n === lastStockImageNum && STOCK_LOADING_IMAGES_COUNT > 1) {
    return randomStockImageNum()
  }
  lastStockImageNum = n
  return n
}

const pickVanillaDriveImageUrl = () =>
  getAssetURL(`images/loading/drive/${randomStockImageNum()}.jpg`)

const loadImage = url =>
  new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(url)
    img.onerror = () => reject(url)
    img.src = url
  })

/** Set URL synchronously on first paint — do not await decode (that recreated world-visible flashes). */
const scheduleBackgroundForShow = () => {
  backgroundUrl.value = pickVanillaDriveImageUrl()
  const primary = backgroundUrl.value
  loadImage(primary).catch(() => {
    const fallback = getAssetURL(`images/loading/drive/${randomStockImageNum()}.jpg`)
    safeLua(loadImage(fallback)
      .then(() => {
        backgroundUrl.value = fallback
      }), "RacingTeamProxyTeamLoading: scheduleBackgroundForShow")
  })
}

const bgStyle = computed(() => ({
  backgroundImage: backgroundUrl.value ? `url('${backgroundUrl.value}')` : "none",
}))

const normalizePayload = raw => {
  if (!raw || typeof raw !== "object") return {}
  if (Array.isArray(raw) && raw.length > 0 && raw[0] && typeof raw[0] === "object" && !Array.isArray(raw[0])) {
    return raw[0]
  }
  return raw
}

const onTeamLoading = (...args) => {
  const d = normalizePayload(args.length > 0 ? args[0] : null)
  if (d.visible === true) {
    message.value = typeof d.message === "string" ? d.message : ""
    scheduleBackgroundForShow()
    visible.value = true
  } else {
    visible.value = false
    message.value = ""
    backgroundUrl.value = null
  }
}

onMounted(() => {
  bridge.events.on("racingTeamProxyTeamLoading", onTeamLoading)
})

onBeforeUnmount(() => {
  bridge.events.off("racingTeamProxyTeamLoading", onTeamLoading)
})
</script>

<style scoped lang="scss">
.rtp-team-load-overlay {
  position: fixed;
  inset: 0;
  z-index: 14100;
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background-color: #000;
  isolation: isolate;
  pointer-events: auto;
}

.rtp-team-load-overlay__bg {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  width: 100vw;
  height: 100vh;
  background-size: cover;
  background-position: center center;
  z-index: 1;
}

.rtp-team-load-overlay__scrim {
  position: absolute;
  inset: 0;
  z-index: 2;
  background: rgba(0, 0, 0, 0.42);
  pointer-events: none;
}

.rtp-team-load-overlay__content {
  position: relative;
  z-index: 3;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
}

.rtp-team-load-overlay__panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.75rem;
  padding: 1.25rem 1.5rem;
  border-radius: 10px;
  background: rgba(20, 22, 28, 0.72);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35);
}

.rtp-team-load-overlay__spinner {
  width: 36px;
  height: 36px;
  border: 3px solid rgba(255, 255, 255, 0.15);
  border-top-color: rgba(255, 255, 255, 0.85);
  border-radius: 50%;
  animation: rtp-team-load-spin 0.75s linear infinite;
}

.rtp-team-load-overlay__msg {
  margin: 0;
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.88);
  text-align: center;
  max-width: 18rem;
}

.rtp-team-load-overlay__cache {
  position: absolute;
  top: 0;
  left: 0;
  width: 1px;
  height: 1px;
  opacity: 0.01;
  overflow: hidden;
  pointer-events: none;
  > img {
    width: 1px;
    height: 1px;
  }
}

@keyframes rtp-team-load-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
