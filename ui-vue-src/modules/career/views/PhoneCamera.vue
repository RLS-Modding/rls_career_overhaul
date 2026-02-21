<template>
  <PhoneWrapper app-name="Camera" :hide-status-bar-gradient="true">
    <div class="camera-app" :class="orientation">
      <!-- Viewfinder -->
      <div class="viewfinder" @click="triggerFocus">
        <Transition name="fade" mode="out-in">
          <img
            v-if="previewSrc"
            key="preview"
            :src="previewSrc"
            class="viewfinder-feed"
            alt="Live view"
          />
          <div v-else key="loading" class="viewfinder-loading">
            <div class="spinner"></div>
          </div>
        </Transition>

        <!-- Focus Ring Animation -->
        <div
          v-if="focusing"
          class="focus-ring"
          :style="{ top: focusPos.y + 'px', left: focusPos.x + 'px' }"
        ></div>

        <!-- Grid Overlay (Rule of Thirds) -->
        <div class="grid-overlay" v-if="showGrid">
          <div class="grid-line h-line top"></div>
          <div class="grid-line h-line bottom"></div>
          <div class="grid-line v-line left"></div>
          <div class="grid-line v-line right"></div>
        </div>
      </div>

      <!-- Top Controls -->
      <div class="top-controls">
        <button class="icon-btn" @click="toggleFlash">
          <!-- Flash Off -->
          <svg v-if="flashMode === 'off'" viewBox="0 0 24 24" width="24" height="24" stroke="currentColor" stroke-width="2" fill="none"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/><line x1="2" y1="2" x2="22" y2="22"/></svg>
          <!-- Flash On (Only when taking picture) -->
          <svg v-else-if="flashMode === 'on'" viewBox="0 0 24 24" width="24" height="24" stroke="currentColor" stroke-width="2" fill="none"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
          <!-- Torch (Always on) -->
          <svg v-else-if="flashMode === 'torch'" viewBox="0 0 24 24" width="24" height="24" stroke="currentColor" stroke-width="2" fill="currentColor"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
        </button>
        <button class="icon-btn" @click="toggleGrid">
          <svg viewBox="0 0 24 24" width="24" height="24" stroke="currentColor" stroke-width="2" fill="none"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="9" y1="3" x2="9" y2="21"/><line x1="15" y1="3" x2="15" y2="21"/></svg>
        </button>
        <button class="icon-btn" @click="toggleTimer">
          <svg viewBox="0 0 24 24" width="24" height="24" stroke="currentColor" stroke-width="2" fill="none"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
          <span v-if="timer > 0" class="timer-badge">{{ timer }}s</span>
        </button>
      </div>

      <!-- Orientation Toggle -->
      <div class="orientation-pill">
        <button
          class="pill-btn"
          :class="{ active: orientation === 'portrait' }"
          @click="setOrientation('portrait')"
        >
          Portrait
        </button>
        <button
          class="pill-btn"
          :class="{ active: orientation === 'landscape' }"
          @click="setOrientation('landscape')"
        >
          Landscape
        </button>
      </div>

      <!-- Bottom Controls -->
      <div class="bottom-controls">
        <!-- Gallery Thumbnail -->
        <button class="gallery-thumb" @click="openGallery">
          <img v-if="latestPhoto" :src="latestPhoto" alt="Gallery" />
          <div v-else class="empty-thumb"></div>
        </button>

        <!-- Shutter Button -->
        <button
          class="shutter-btn"
          :class="{ taking: taking || countdown > 0 }"
          @click="takePhoto"
          :disabled="taking || countdown > 0"
        >
          <div class="shutter-ring"></div>
          <div class="shutter-inner">
            <span v-if="countdown > 0" class="countdown-text">{{ countdown }}</span>
          </div>
        </button>

        <!-- Empty spacer to keep shutter centered -->
        <div class="spacer" style="width: 56px;"></div>
      </div>

      <!-- Shutter Flash -->
      <div class="shutter-flash" :class="{ active: flashActive }"></div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
import { ref, onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'

const router = useRouter()
const events = useEvents()

const taking = ref(false)
const previewSrc = ref(null)
const orientation = ref('portrait')
const latestPhoto = ref(null)
const flashActive = ref(false)
const countdown = ref(0)

// UI State
const flashMode = ref('off') // off, on, torch
const showGrid = ref(false)
const timer = ref(0) // 0, 3, 10
const focusing = ref(false)
const focusPos = ref({ x: 0, y: 0 })

function onPreviewFrame(dataUrl) {
  if (dataUrl) previewSrc.value = dataUrl
}

function setOrientation(value) {
  if (value !== 'landscape' && value !== 'portrait') return
  orientation.value = value
  lua.gameplay_phoneCamera.setPreviewOrientation(value)
}

function toggleFlash() {
  const modes = ['off', 'on', 'torch']
  flashMode.value = modes[(modes.indexOf(flashMode.value) + 1) % modes.length]
  
  // Tell Lua to turn the persistent torch on or off
  lua.gameplay_phoneCamera.setTorchMode(flashMode.value === 'torch')
}

function toggleGrid() {
  showGrid.value = !showGrid.value
}

function toggleTimer() {
  const times = [0, 3, 10]
  timer.value = times[(times.indexOf(timer.value) + 1) % times.length]
}

function triggerFocus(e) {
  if (focusing.value) return
  const rect = e.currentTarget.getBoundingClientRect()
  focusPos.value = {
    x: e.clientX - rect.left,
    y: e.clientY - rect.top
  }
  focusing.value = true
  setTimeout(() => {
    focusing.value = false
  }, 1000)
}

function flipCamera(e) {
  const btn = e.currentTarget
  btn.style.transform = 'rotate(180deg)'
  setTimeout(() => {
    btn.style.transition = 'none'
    btn.style.transform = 'rotate(0deg)'
    setTimeout(() => {
      btn.style.transition = 'transform 0.4s cubic-bezier(0.4, 0, 0.2, 1)'
    }, 50)
  }, 400)
}

function openGallery() {
  router.push({ name: 'phone-gallery' })
}

async function fetchLatestPhoto() {
  try {
    const list = await lua.gameplay_phoneCamera.getPhotoList()
    if (list && list.length > 0) {
      // The list is sorted newest first, so we take the first one
      const latest = list[0]
      latestPhoto.value = await lua.gameplay_phoneCamera.getPhotoAsDataUrl(latest.filename)
    }
  } catch (e) {
    console.error('Failed to fetch latest photo', e)
  }
}

onMounted(() => {
  events.on('PhoneCameraPreviewFrame', onPreviewFrame)
  lua.gameplay_phoneCamera.startPreview()
  lua.gameplay_phoneCamera.setPreviewOrientation(orientation.value)
  fetchLatestPhoto()
  
  // Ensure torch state matches UI state on mount
  if (flashMode.value === 'torch') {
    lua.gameplay_phoneCamera.setTorchMode(true)
  }
  
  // Initial focus animation in center
  setTimeout(() => {
    const viewfinder = document.querySelector('.viewfinder')
    if (viewfinder) {
      focusPos.value = {
        x: viewfinder.clientWidth / 2,
        y: viewfinder.clientHeight / 2
      }
      focusing.value = true
      setTimeout(() => { focusing.value = false }, 1000)
    }
  }, 500)
})

onUnmounted(() => {
  events.off('PhoneCameraPreviewFrame', onPreviewFrame)
  lua.gameplay_phoneCamera.stopPreview()
  
  // Ensure torch is turned off when leaving the app
  if (flashMode.value === 'torch') {
    lua.gameplay_phoneCamera.setTorchMode(false)
  }
})

async function takePhoto() {
  if (taking.value || countdown.value > 0) return
  
  if (timer.value > 0) {
    countdown.value = timer.value
    
    // Simple countdown loop
    while (countdown.value > 0) {
      await new Promise(resolve => setTimeout(resolve, 1000))
      countdown.value--
    }
  }

  taking.value = true
  
  // Determine if flash should be used
  let useFlash = false
  if (flashMode.value === 'on') {
    useFlash = true
  } else if (flashMode.value === 'torch') {
    // If torch is on, we don't need to spawn a temporary flash, the torch is already lighting the scene
    useFlash = false 
  }

  // Trigger UI flash effect
  flashActive.value = true
  setTimeout(() => { flashActive.value = false }, 150)

  try {
    await lua.gameplay_phoneCamera.takePhoto(orientation.value, useFlash)
    // Refresh thumbnail after taking photo
    setTimeout(fetchLatestPhoto, 500)
  } catch (e) {
    console.error('Camera takePhoto failed', e)
  } finally {
    taking.value = false
  }
}
</script>

<style scoped lang="scss">
$ease-out: cubic-bezier(0.22, 1, 0.36, 1);
$ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);
$glass-bg: rgba(0, 0, 0, 0.4);
$glass-blur: 20px;

.camera-app {
  position: relative;
  width: 100%;
  height: 100%;
  background: #000;
  color: #fff;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}

/* Viewfinder */
.viewfinder {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  z-index: 1;
}

.viewfinder-feed {
  width: 100%;
  height: 100%;
  object-fit: cover;
  transition: transform 0.4s $ease-out;
}

.camera-app.landscape .viewfinder-feed {
  /* In landscape mode, we might want to show a letterboxed view or just keep it cover */
  object-fit: contain;
  background: #000;
}

.viewfinder-loading {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #111;
}

.spinner {
  width: 40px;
  height: 40px;
  border: 3px solid rgba(255, 255, 255, 0.2);
  border-top-color: #fff;
  border-radius: 50%;
  animation: spin 1s linear infinite;
}

/* Grid Overlay */
.grid-overlay {
  position: absolute;
  inset: 0;
  pointer-events: none;
  z-index: 2;
}

.grid-line {
  position: absolute;
  background: rgba(255, 255, 255, 0.3);
}

.h-line { width: 100%; height: 1px; left: 0; }
.h-line.top { top: 33.33%; }
.h-line.bottom { top: 66.66%; }

.v-line { height: 100%; width: 1px; top: 0; }
.v-line.left { left: 33.33%; }
.v-line.right { left: 66.66%; }

/* Focus Ring */
.focus-ring {
  position: absolute;
  width: 60px;
  height: 60px;
  margin-top: -30px;
  margin-left: -30px;
  border: 2px solid #ffd700;
  border-radius: 50%;
  pointer-events: none;
  z-index: 3;
  animation: focusPulse 1s $ease-out forwards;
  box-shadow: 0 0 4px rgba(0,0,0,0.5);
}

/* Top Controls */
.top-controls {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  padding: 64px 24px 16px; /* Increased top padding to clear the phone's back button */
  display: flex;
  justify-content: space-between;
  align-items: center;
  z-index: 10;
  pointer-events: none; /* Let clicks pass through the empty space */
}

.icon-btn {
  pointer-events: auto; /* Re-enable clicks on the actual buttons */
  background: rgba(0, 0, 0, 0.3);
  border: none;
  color: #fff;
  width: 44px;
  height: 44px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  transition: background 0.2s, transform 0.2s;
  position: relative;

  &:hover {
    background: rgba(255, 255, 255, 0.2);
  }
  &:active {
    transform: scale(0.9);
  }
}

.timer-badge {
  position: absolute;
  top: -4px;
  right: -4px;
  background: #ffd700;
  color: #000;
  font-size: 10px;
  font-weight: bold;
  padding: 2px 4px;
  border-radius: 8px;
}

/* Orientation Pill */
.orientation-pill {
  position: absolute;
  bottom: 140px;
  left: 50%;
  transform: translateX(-50%);
  display: flex;
  background: rgba(0, 0, 0, 0.5);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  border-radius: 20px;
  padding: 4px;
  z-index: 10;
  box-shadow: 0 4px 12px rgba(0,0,0,0.3);
}

.pill-btn {
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.7);
  padding: 6px 16px;
  border-radius: 16px;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.3s $ease-out;

  &.active {
    background: #fff;
    color: #000;
    box-shadow: 0 2px 8px rgba(0,0,0,0.2);
  }
}

/* Bottom Controls */
.bottom-controls {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 120px;
  background: linear-gradient(to top, rgba(0,0,0,0.8) 0%, transparent 100%);
  display: flex;
  align-items: center;
  justify-content: space-around;
  padding: 0 24px 24px;
  z-index: 10;
}

.gallery-thumb {
  width: 56px;
  height: 56px;
  border-radius: 12px;
  border: 2px solid rgba(255, 255, 255, 0.2);
  background: rgba(255, 255, 255, 0.1);
  overflow: hidden;
  cursor: pointer;
  padding: 0;
  transition: transform 0.2s, border-color 0.2s;

  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  &:hover {
    transform: scale(1.05);
    border-color: rgba(255, 255, 255, 0.5);
  }
  &:active {
    transform: scale(0.95);
  }
}

.empty-thumb {
  width: 100%;
  height: 100%;
  background: linear-gradient(45deg, #333, #555);
}

.shutter-btn {
  position: relative;
  width: 80px;
  height: 80px;
  border: none;
  background: transparent;
  cursor: pointer;
  padding: 0;
  display: flex;
  align-items: center;
  justify-content: center;

  .shutter-ring {
    position: absolute;
    inset: 0;
    border-radius: 50%;
    border: 4px solid #fff;
    transition: transform 0.2s $ease-out;
  }

  .shutter-inner {
    width: 64px;
    height: 64px;
    border-radius: 50%;
    background: #fff;
    transition: all 0.2s $ease-out;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .countdown-text {
    color: #000;
    font-size: 24px;
    font-weight: bold;
    animation: popIn 0.3s $ease-out;
  }

  &:hover:not(:disabled) {
    .shutter-inner {
      transform: scale(0.95);
    }
  }

  &:active:not(:disabled), &.taking {
    .shutter-inner {
      transform: scale(0.85);
      background: #e0e0e0;
    }
    .shutter-ring {
      transform: scale(1.05);
    }
  }
}

.flip-btn {
  width: 56px;
  height: 56px;
  background: rgba(255, 255, 255, 0.15);
  transition: transform 0.4s cubic-bezier(0.4, 0, 0.2, 1), background 0.2s;
}

/* Shutter Flash */
.shutter-flash {
  position: absolute;
  inset: 0;
  background: #fff;
  opacity: 0;
  pointer-events: none;
  z-index: 100;
  transition: opacity 0.15s ease-out;

  &.active {
    opacity: 1;
    transition: none;
  }
}

/* Animations */
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.3s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

@keyframes focusPulse {
  0% { transform: scale(1.5); opacity: 0; }
  20% { transform: scale(1); opacity: 1; }
  80% { transform: scale(1); opacity: 1; }
  100% { transform: scale(1.1); opacity: 0; }
}

@keyframes popIn {
  0% { transform: scale(0.5); opacity: 0; }
  100% { transform: scale(1); opacity: 1; }
}
</style>
