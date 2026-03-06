<template>
  <div
    ref="dockAreaRef"
    class="phone-dock-area"
    :class="{ 'no-transition': noTransition }"
    :style="dockStyle"
  >
    <!-- Page dots above dock -->
    <div class="dock-page-dots" v-if="totalPages > 0">
      <span
        v-for="i in totalPages"
        :key="'dot-' + i"
        class="dock-dot"
        :class="{ active: currentPage === i - 1 }"
        @click="$emit('goPage', i - 1)"
      ></span>
      <span
        class="dock-dot search-dot"
        :class="{ active: isSearchActive }"
        @click="$emit('goPage', totalPages)"
      >
        <svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="11" cy="11" r="8"/>
          <line x1="21" y1="21" x2="16.65" y2="16.65"/>
        </svg>
      </span>
    </div>
    <div
      ref="dockRef"
      class="phone-dock"
      @pointerup="onDockPointerUp"
    >
      <div
        v-if="showDockBackground"
        class="dock-bg-image"
        :style="dockBackgroundStyle"
      ></div>
      <div
        v-for="(app, idx) in dockApps"
        :key="app ? app.id : 'empty-' + idx"
        class="dock-slot"
        :class="{ 'dock-slot-highlight': highlightIndex === idx }"
        :data-dock-index="idx"
      >
        <template v-if="app">
          <div
            class="dock-icon-wrap"
            :title="app.name"
            @click.stop="!jiggleMode && $emit('launch', app)"
            @pointerdown.stop="onIconPointerDown($event, app, idx)"
          >
            <PhoneAppIcon
              :app="app"
              :jiggle-mode="jiggleMode"
              :jiggle-offset="idx"
              :show-label="false"
              @launch="$emit('launch', $event)"
              @longpress="$emit('longpress', $event)"
              @dragstart="(e, a) => $emit('dragstart', e, a, 'dock', idx)"
              @remove="$emit('remove', $event)"
            />
          </div>
        </template>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import PhoneAppIcon from './PhoneAppIcon.vue'

const props = defineProps({
  dockIds: { type: Array, required: true },
  appMap: { type: Object, required: true },
  jiggleMode: { type: Boolean, default: false },
  highlightIndex: { type: Number, default: -1 },
  totalPages: { type: Number, default: 0 },
  currentPage: { type: Number, default: 0 },
  isSearchActive: { type: Boolean, default: false },
  slideOffset: { type: Number, default: 0 },
  noTransition: { type: Boolean, default: false },
  backgroundImage: { type: String, default: '' },
})

const dockStyle = computed(() => {
  return { transform: `translateX(${props.slideOffset}px)` }
})

const emit = defineEmits(['launch', 'longpress', 'dragstart', 'goPage', 'remove'])
const dockAreaRef = ref(null)
const dockRef = ref(null)
const imageMetrics = reactive({ width: 0, height: 0 })
const dockBgMetrics = reactive({ left: 0, top: 0, width: 0, height: 0, ready: false })
let resizeHandler = null

const dockApps = computed(() => {
  return props.dockIds.map(id => id ? props.appMap[id] || null : null)
})

const showDockBackground = computed(() => {
  return !!props.backgroundImage && dockBgMetrics.ready
})

const dockBackgroundStyle = computed(() => ({
  width: `${dockBgMetrics.width}px`,
  height: `${dockBgMetrics.height}px`,
  left: `${dockBgMetrics.left}px`,
  top: `${dockBgMetrics.top}px`,
  backgroundImage: `url(${props.backgroundImage})`,
}))

function resetDockBackground() {
  dockBgMetrics.left = 0
  dockBgMetrics.top = 0
  dockBgMetrics.width = 0
  dockBgMetrics.height = 0
  dockBgMetrics.ready = false
}

function updateDockBackground() {
  if (!dockRef.value || !dockAreaRef.value || !props.backgroundImage || !imageMetrics.width || !imageMetrics.height) {
    resetDockBackground()
    return
  }

  const homescreenEl = dockAreaRef.value.closest('.homescreen')
  if (!homescreenEl) {
    resetDockBackground()
    return
  }

  const homescreenRect = homescreenEl.getBoundingClientRect()
  const dockRect = dockRef.value.getBoundingClientRect()
  if (!homescreenRect.width || !homescreenRect.height || !dockRect.width || !dockRect.height) {
    resetDockBackground()
    return
  }

  const coverScale = Math.max(
    homescreenRect.width / imageMetrics.width,
    homescreenRect.height / imageMetrics.height,
  )
  const renderedWidth = imageMetrics.width * coverScale
  const renderedHeight = imageMetrics.height * coverScale
  const imageLeft = (homescreenRect.width - renderedWidth) * 0.5
  const imageTop = (homescreenRect.height - renderedHeight) * 0.5
  const dockLeft = dockRect.left - homescreenRect.left
  const dockTop = dockRect.top - homescreenRect.top

  dockBgMetrics.left = imageLeft - dockLeft
  dockBgMetrics.top = imageTop - dockTop
  dockBgMetrics.width = renderedWidth
  dockBgMetrics.height = renderedHeight
  dockBgMetrics.ready = true
}

function loadBackgroundImage() {
  if (!props.backgroundImage) {
    imageMetrics.width = 0
    imageMetrics.height = 0
    resetDockBackground()
    return
  }

  const img = new Image()
  img.onload = () => {
    imageMetrics.width = img.naturalWidth
    imageMetrics.height = img.naturalHeight
    nextTick(updateDockBackground)
  }
  img.onerror = () => {
    imageMetrics.width = 0
    imageMetrics.height = 0
    resetDockBackground()
  }
  img.src = props.backgroundImage
}

function onIconPointerDown(e, app, idx) {
  if (props.jiggleMode) {
    emit('dragstart', e, app, 'dock', idx)
  }
}

function onDockPointerUp() {
  // handled by parent drag system
}

watch(() => props.backgroundImage, () => {
  loadBackgroundImage()
})

watch(() => props.slideOffset, () => {
  nextTick(updateDockBackground)
})

onMounted(() => {
  resizeHandler = () => updateDockBackground()
  window.addEventListener('resize', resizeHandler)
  loadBackgroundImage()
  nextTick(updateDockBackground)
})

onUnmounted(() => {
  if (resizeHandler) {
    window.removeEventListener('resize', resizeHandler)
    resizeHandler = null
  }
})
</script>

<style scoped lang="scss">
.phone-dock-area {
  position: absolute;
  bottom: 32px;
  left: 0;
  right: 0;
  z-index: 20;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  transition: transform 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94);

  &.no-transition {
    transition: none;
  }
}

.no-transition .phone-dock::before {
  transition: none;
}

.dock-page-dots {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
}

.dock-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.3);
  cursor: pointer;
  transition: background 0.2s ease, transform 0.2s ease;

  &.active {
    background: rgba(var(--bng-add-blue-400-rgb), 0.95);
    box-shadow: 0 0 10px rgba(var(--bng-add-blue-400-rgb), 0.55);
    transform: scale(1.2);
  }
}

.search-dot {
  width: auto;
  height: auto;
  background: none;
  opacity: 0.4;
  color: rgba(255, 255, 255, 0.9);
  display: flex;
  align-items: center;
  justify-content: center;
  transition: opacity 0.2s ease;

  &.active {
    opacity: 1;
    transform: scale(1.15);
    background: none;
  }
}

.phone-dock {
  width: 350px;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 16px;
  padding: 15px;
  position: relative;
  overflow: hidden;
  border: 1px solid rgba(var(--bng-add-blue-400-rgb), 0.22);
  border-radius: 30px;
  box-sizing: border-box;
  box-shadow:
    0 0 0 1px rgba(var(--bng-add-blue-500-rgb), 0.08),
    0 10px 28px rgba(0, 0, 0, 0.28);

  &::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background:
      linear-gradient(180deg, rgba(var(--bng-ter-blue-gray-700-rgb), 0.26), rgba(var(--bng-ter-blue-gray-900-rgb), 0.34)),
      rgba(20, 20, 20, 0.34);
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
    pointer-events: none;
  }
}

.dock-bg-image {
  position: absolute;
  background-repeat: no-repeat;
  background-size: 100% 100%;
  filter: blur(5px) saturate(1.15);
  transition:
    left 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94),
    top 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94),
    width 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94),
    height 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94);
}

.dock-slot {
  width: 68px;
  height: 68px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  border-radius: 18px;
  transition: background 0.15s ease;
  flex: 0 0 auto;
  position: relative;
  z-index: 1;

  &.dock-slot-highlight {
    background: rgba(var(--bng-add-blue-500-rgb), 0.2);
    box-shadow: inset 0 0 0 1px rgba(var(--bng-add-blue-400-rgb), 0.24);
  }
}

.dock-icon-wrap {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 68px;
  height: 68px;
}

:deep(.app-icon-square) {
  width: 68px;
  height: 68px;
}
</style>
