<template>
  <PhoneWrapper app-name="Camera" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="camera-container">
      <!-- Full-screen viewfinder; in landscape the preview is a 4:3 box that fits the screen -->
      <div class="camera-viewfinder" :class="orientation">
        <div class="viewfinder-frame">
          <img
            v-if="previewSrc"
            :src="previewSrc"
            class="viewfinder-image"
            alt="Live view"
          />
          <div v-else class="viewfinder-placeholder">
            <span>Loading...</span>
          </div>
        </div>
      </div>

      <!-- Top bar: overlay, black ~75% transparent -->
      <div class="camera-top-bar">
        <div class="orientation-toggle">
          <button
            class="orientation-btn"
            :class="{ active: orientation === 'portrait' }"
            @click="setOrientation('portrait')"
          >
            Portrait
          </button>
          <button
            class="orientation-btn"
            :class="{ active: orientation === 'landscape' }"
            @click="setOrientation('landscape')"
          >
            Landscape
          </button>
        </div>
      </div>

      <!-- Bottom bar: overlay, black ~75% transparent, capture button centered -->
      <div class="camera-bottom-bar">
        <button
          class="capture-btn"
          :disabled="taking"
          :class="{ taking: taking }"
          @click="takePhoto"
        />
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
import { ref, onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'

const events = useEvents()
const taking = ref(false)
const previewSrc = ref(null)
const orientation = ref('portrait')

function onPreviewFrame(dataUrl) {
  if (dataUrl) previewSrc.value = dataUrl
}

function setOrientation(value) {
  if (value !== 'landscape' && value !== 'portrait') return
  orientation.value = value
  lua.gameplay_phoneCamera.setPreviewOrientation(value)
}

onMounted(() => {
  events.on('PhoneCameraPreviewFrame', onPreviewFrame)
  lua.gameplay_phoneCamera.startPreview()
  lua.gameplay_phoneCamera.setPreviewOrientation(orientation.value)
})

onUnmounted(() => {
  events.off('PhoneCameraPreviewFrame', onPreviewFrame)
  lua.gameplay_phoneCamera.stopPreview()
})

async function takePhoto() {
  if (taking.value) return
  taking.value = true
  try {
    await lua.gameplay_phoneCamera.takePhoto(orientation.value)
  } catch (e) {
    console.error('Camera takePhoto failed', e)
  } finally {
    taking.value = false
  }
}
</script>

<style scoped lang="scss">
$bar-bg: rgba(0, 0, 0, 0.75);
$viewfinder-bg: #6b7a82;

.camera-container {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 100%;
  box-sizing: border-box;
  overflow: hidden;
}

/* Full-screen viewfinder */
.camera-viewfinder {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  background: #0a0a0a;

  /* Portrait: frame fills whole screen */
  &.portrait .viewfinder-frame {
    width: 100%;
    height: 100%;
  }

  /* Landscape: 4:3 wide frame centered, fits on screen (letterboxed on portrait phone) */
  &.landscape {
    display: flex;
    align-items: center;
    justify-content: center;
  }

  &.landscape .viewfinder-frame {
    width: 100%;
    max-width: min(100%, 133.333vh); /* so 4:3 box never taller than viewport */
    height: 0;
    padding-bottom: 75%; /* 3/4 = 4:3 landscape */
    position: relative;
  }

  &.landscape .viewfinder-image,
  &.landscape .viewfinder-placeholder {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
  }

  .viewfinder-frame {
    overflow: hidden;
    background: $viewfinder-bg;
  }

  .viewfinder-image {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  &.landscape .viewfinder-image {
    object-fit: cover;
  }

  .viewfinder-placeholder {
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.85rem;
  }
}

/* Top bar: overlay, black 75% transparent */
.camera-top-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  min-height: 44px;
  background: $bar-bg;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 8px 12px;
}

.orientation-toggle {
  display: flex;
  gap: 6px;
}

.orientation-btn {
  padding: 6px 14px;
  border-radius: 6px;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.8rem;
  cursor: pointer;
  transition: color 0.2s ease, background 0.2s ease;

  &.active {
    background: rgba(255, 255, 255, 0.12);
    color: #fff;
  }

  &:hover:not(.active) {
    color: rgba(255, 255, 255, 0.8);
  }
}

/* Bottom bar: overlay, black 75% transparent, capture button centered */
.camera-bottom-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  min-height: 72px;
  background: $bar-bg;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 12px;
}

.capture-btn {
  width: 56px;
  height: 56px;
  border-radius: 50%;
  border: 3px solid rgba(255, 255, 255, 0.3);
  background: #fff;
  cursor: pointer;
  padding: 0;
  transition: transform 0.15s ease, opacity 0.2s ease;

  &:hover:not(:disabled) {
    transform: scale(1.05);
  }

  &:active:not(:disabled) {
    transform: scale(0.96);
  }

  &:disabled,
  &.taking {
    opacity: 0.6;
    cursor: not-allowed;
  }
}
</style>
