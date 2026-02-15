<template>
  <PhoneWrapper app-name="Camera">
    <div class="camera-container">
      <!-- Viewfinder with lens feel -->
      <div class="camera-viewfinder" :class="orientation">
        <div class="viewfinder-frame">
          <Transition name="preview-fade" mode="out-in">
            <img
              v-if="previewSrc"
              key="preview"
              :src="previewSrc"
              class="viewfinder-image"
              alt="Live view"
            />
            <div v-else key="loading" class="viewfinder-placeholder">
              <div class="loading-dots">
                <span></span><span></span><span></span>
              </div>
              <span class="loading-label">Camera starting...</span>
            </div>
          </Transition>
        </div>
        <!-- Viewfinder overlay: corner guides + subtle vignette -->
        <div class="viewfinder-overlay" aria-hidden="true">
          <div class="corner tl"></div>
          <div class="corner tr"></div>
          <div class="corner bl"></div>
          <div class="corner br"></div>
        </div>
        <!-- Shutter flash (brief full-screen white on capture) -->
        <div class="shutter-flash" :class="{ active: taking }" aria-hidden="true"></div>
      </div>

      <!-- Top bar: glass -->
      <div class="camera-top-bar">
        <div class="orientation-toggle" role="tablist">
          <button
            type="button"
            role="tab"
            class="orientation-btn"
            :class="{ active: orientation === 'portrait' }"
            :aria-selected="orientation === 'portrait'"
            @click="setOrientation('portrait')"
          >
            <span class="orientation-icon">▯</span>
            Portrait
          </button>
          <button
            type="button"
            role="tab"
            class="orientation-btn"
            :class="{ active: orientation === 'landscape' }"
            :aria-selected="orientation === 'landscape'"
            @click="setOrientation('landscape')"
          >
            <span class="orientation-icon">▭</span>
            Landscape
          </button>
        </div>
      </div>

      <!-- Bottom bar: glass + capture -->
      <div class="camera-bottom-bar">
        <button
          type="button"
          class="capture-btn"
          :disabled="taking"
          :class="{ taking: taking }"
          aria-label="Take photo"
          @click="takePhoto"
        >
          <span class="capture-ring"></span>
          <span class="capture-inner"></span>
        </button>
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
/* Design tokens – in-game phone camera feel */
$glass-bg: rgba(12, 12, 18, 0.82);
$glass-border: rgba(255, 255, 255, 0.08);
$glass-blur: 12px;
$accent: rgba(255, 255, 255, 0.95);
$accent-dim: rgba(255, 255, 255, 0.5);
$viewfinder-bg: #0c0e12;
$corner-color: rgba(255, 255, 255, 0.35);
$ease-out: cubic-bezier(0.22, 1, 0.36, 1);
$ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);

.camera-container {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 100%;
  box-sizing: border-box;
  overflow: hidden;
  background: $viewfinder-bg;
}

/* Viewfinder */
.camera-viewfinder {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  background: $viewfinder-bg;

  &.portrait .viewfinder-frame {
    width: 100%;
    height: 100%;
  }

  &.landscape {
    display: flex;
    align-items: center;
    justify-content: center;
  }

  &.landscape .viewfinder-frame {
    width: 100%;
    max-width: min(100%, 133.333vh);
    height: 0;
    padding-bottom: 75%;
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
    position: relative;
    box-shadow: inset 0 0 80px rgba(0, 0, 0, 0.4);
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
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: $accent-dim;
    font-size: 0.8rem;
  }

  .loading-dots {
    display: flex;
    gap: 6px;
    span {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: $accent-dim;
      animation: dotPulse 1.2s $ease-in-out infinite;
      &:nth-child(2) { animation-delay: 0.15s; }
      &:nth-child(3) { animation-delay: 0.3s; }
    }
  }

  .loading-label {
    letter-spacing: 0.02em;
    opacity: 0.9;
  }
}

/* Corner guides + vignette overlay */
.viewfinder-overlay {
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: radial-gradient(
    ellipse 80% 80% at 50% 50%,
    transparent 60%,
    rgba(0, 0, 0, 0.25) 100%
  );

  .corner {
    position: absolute;
    width: 24px;
    height: 24px;
    border-color: $corner-color;
    border-style: solid;
    border-width: 0;
    opacity: 0.9;
  }
  .tl { top: 12px; left: 12px; border-top-width: 2px; border-left-width: 2px; border-radius: 4px 0 0 0; }
  .tr { top: 12px; right: 12px; border-top-width: 2px; border-right-width: 2px; border-radius: 0 4px 0 0; }
  .bl { bottom: 12px; left: 12px; border-bottom-width: 2px; border-left-width: 2px; border-radius: 0 0 0 4px; }
  .br { bottom: 12px; right: 12px; border-bottom-width: 2px; border-right-width: 2px; border-radius: 0 0 4px 0; }
}

/* Shutter flash */
.shutter-flash {
  position: absolute;
  inset: 0;
  background: rgba(255, 255, 255, 0.9);
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.08s ease-out;

  &.active {
    animation: shutterFlash 0.25s $ease-out forwards;
  }
}

/* Top bar – glass; extra top padding clears status bar, buttons sit in the space below */
.camera-top-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  min-height: 48px;
  padding-top: calc(36px + 0.5em + 0.6em);
  padding-left: 16px;
  padding-right: 16px;
  padding-bottom: 10px;
  background: $glass-bg;
  backdrop-filter: blur($glass-blur);
  -webkit-backdrop-filter: blur($glass-blur);
  border-bottom: 1px solid $glass-border;
  display: flex;
  align-items: center;
  justify-content: center;
  animation: barSlideDown 0.35s $ease-out;
}

.orientation-toggle {
  display: flex;
  gap: 4px;
  padding: 4px;
  background: rgba(0, 0, 0, 0.35);
  border-radius: 12px;
  border: 1px solid $glass-border;
}

.orientation-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  border-radius: 8px;
  border: none;
  background: transparent;
  color: $accent-dim;
  font-size: 0.8rem;
  font-weight: 500;
  letter-spacing: 0.02em;
  cursor: pointer;
  transition: color 0.2s $ease-out, background 0.2s $ease-out, transform 0.15s $ease-out;

  .orientation-icon {
    font-size: 0.9em;
    opacity: 0.8;
  }

  &.active {
    background: rgba(255, 255, 255, 0.18);
    color: $accent;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
  }

  &:hover:not(.active) {
    color: rgba(255, 255, 255, 0.85);
    background: rgba(255, 255, 255, 0.06);
  }

  &:active {
    transform: scale(0.98);
  }
}

/* Bottom bar – glass */
.camera-bottom-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  min-height: 88px;
  background: $glass-bg;
  backdrop-filter: blur($glass-blur);
  -webkit-backdrop-filter: blur($glass-blur);
  border-top: 1px solid $glass-border;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  animation: barSlideUp 0.35s $ease-out;
}

.capture-btn {
  position: relative;
  width: 64px;
  height: 64px;
  border: none;
  background: transparent;
  cursor: pointer;
  padding: 0;
  transition: transform 0.2s $ease-out, opacity 0.2s ease;

  .capture-ring {
    position: absolute;
    inset: -4px;
    border-radius: 50%;
    border: 3px solid rgba(255, 255, 255, 0.5);
    background: transparent;
    transition: border-color 0.2s ease, transform 0.2s $ease-out;
  }

  .capture-inner {
    position: absolute;
    inset: 6px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 2px 12px rgba(0, 0, 0, 0.35);
    transition: transform 0.2s $ease-out, box-shadow 0.2s ease;
  }

  &:hover:not(:disabled):not(.taking) {
    transform: scale(1.06);
    .capture-ring { border-color: rgba(255, 255, 255, 0.8); }
    .capture-inner { box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4); }
  }

  &:active:not(:disabled):not(.taking) {
    transform: scale(0.94);
    .capture-inner { transform: scale(0.92); box-shadow: 0 1px 6px rgba(0, 0, 0, 0.4); }
  }

  &:disabled,
  &.taking {
    opacity: 0.6;
    cursor: not-allowed;
    transform: scale(0.98);
  }
}

/* Transitions */
.preview-fade-enter-active,
.preview-fade-leave-active {
  transition: opacity 0.2s $ease-out;
}
.preview-fade-enter-from,
.preview-fade-leave-to {
  opacity: 0;
}

@keyframes dotPulse {
  0%, 100% { opacity: 0.4; transform: scale(0.9); }
  50% { opacity: 1; transform: scale(1.1); }
}

@keyframes shutterFlash {
  0% { opacity: 0.9; }
  40% { opacity: 0.9; }
  100% { opacity: 0; }
}

@keyframes barSlideDown {
  from {
    opacity: 0;
    transform: translateY(-12px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

@keyframes barSlideUp {
  from {
    opacity: 0;
    transform: translateY(12px);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
</style>
