<template>
  <div class="phone-search">
    <div class="search-input-wrap">
      <svg class="search-icon-svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="11" cy="11" r="8"/>
        <line x1="21" y1="21" x2="16.65" y2="16.65"/>
      </svg>
      <input
        ref="searchInputRef"
        v-model="query"
        v-bng-text-input
        class="search-input"
        placeholder="Search apps..."
      />
    </div>
    <div class="search-results">
      <div
        v-for="app in filteredApps"
        :key="app.id"
        class="search-result-item"
        @pointerdown="onResultPointerDown($event, app)"
        @click="onResultClick(app)"
      >
        <div class="search-result-icon" :style="{ backgroundColor: app.iconImage ? 'transparent' : app.color }">
          <img
            v-if="app.iconImage"
            class="search-result-icon-image"
            :src="app.iconImage"
            :alt="app.name"
            :style="{ objectFit: app.iconImageFit || 'cover' }"
            draggable="false"
          />
          <div v-if="app.iconImage && app.iconImageOverlay" class="search-result-icon-overlay"></div>
          <BngIcon v-else :type="app.icon" :style="{ color: app.iconColor }" />
        </div>
        <div class="search-result-info">
          <span class="search-result-name">{{ app.name }}</span>
          <span class="search-result-category" v-if="app.category">{{ app.category }}</span>
        </div>
        <span class="search-result-new" v-if="!seenApps.has(app.id)">NEW</span>
        <span class="search-result-add-hint" v-if="jiggleMode && !appIdsOnHome.has(app.id)">Hold to add</span>
      </div>
    </div>
    <Teleport to="body">
      <div
        v-if="contextMenu.app"
        class="search-context-modal"
        @click.self="contextMenu.app = null"
        ref="contextMenuRef"
      >
        <div
          class="search-context-menu"
          :style="{ left: contextMenu.x + 'px', top: contextMenu.y + 'px' }"
        >
          <button class="context-menu-btn" @click="onPutOnHome">
            Put on Home Screen
          </button>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { ref, computed, reactive, onUnmounted, onMounted } from 'vue'
import { BngIcon } from '@/common/components/base'
import { vBngTextInput } from '@/common/directives'

const props = defineProps({
  apps: { type: Array, required: true },
  seenApps: { type: Set, default: () => new Set() },
  jiggleMode: { type: Boolean, default: false },
  appIdsOnHome: { type: Set, default: () => new Set() },
})

const emit = defineEmits(['launch', 'addToHome', 'dragstart'])

const query = ref('')
const searchInputRef = ref(null)
const contextMenuRef = ref(null)
const contextMenu = reactive({ app: null, x: 0, y: 0 })
let suppressNextLaunch = false
let cleanupPointerTracking = null

const filteredApps = computed(() => {
  const sorted = [...props.apps].sort((a, b) => a.name.localeCompare(b.name))
  if (!query.value.trim()) return sorted
  const q = query.value.toLowerCase()
  return sorted.filter(a =>
    a.name.toLowerCase().includes(q) ||
    (a.category && a.category.toLowerCase().includes(q))
  )
})

let longPressTimer = null

function onResultPointerDown(e, app) {
  if (cleanupPointerTracking) {
    cleanupPointerTracking()
    cleanupPointerTracking = null
  }

  let moved = false
  const startX = e.clientX
  const startY = e.clientY

  if (props.jiggleMode) {
    longPressTimer = setTimeout(() => {
      longPressTimer = null
      if (!moved) {
        suppressNextLaunch = true
        showContextMenu(app, startX, startY)
      }
      cleanupPointerTracking?.()
      cleanupPointerTracking = null
    }, 600)
  }

  const onMove = (ev) => {
    if (Math.abs(ev.clientX - startX) > 8 || Math.abs(ev.clientY - startY) > 8) {
      moved = true
      if (longPressTimer) {
        clearTimeout(longPressTimer)
        longPressTimer = null
      }
      if (props.jiggleMode) {
        emit('dragstart', ev, app)
        cleanupPointerTracking?.()
        cleanupPointerTracking = null
      }
    }
  }

  const onUp = () => {
    if (longPressTimer) {
      clearTimeout(longPressTimer)
      longPressTimer = null
    }
    suppressNextLaunch = moved
    if (cleanupPointerTracking) {
      cleanupPointerTracking()
      cleanupPointerTracking = null
    }
  }

  cleanupPointerTracking = () => {
    document.removeEventListener('pointermove', onMove)
    document.removeEventListener('pointerup', onUp)
    document.removeEventListener('pointercancel', onUp)
  }

  document.addEventListener('pointermove', onMove)
  document.addEventListener('pointerup', onUp)
  document.addEventListener('pointercancel', onUp)
}

function showContextMenu(app, x, y) {
  if (props.appIdsOnHome.has(app.id)) return
  contextMenu.app = app
  contextMenu.x = x
  contextMenu.y = y
}

function onPutOnHome() {
  if (contextMenu.app) {
    emit('addToHome', contextMenu.app)
    contextMenu.app = null
  }
}

function closeContextMenu(e) {
  if (contextMenu.app && contextMenuRef.value && !contextMenuRef.value.contains(e.target)) {
    contextMenu.app = null
  }
}

function onResultClick(app) {
  if (suppressNextLaunch) {
    suppressNextLaunch = false
    return
  }
  emit('launch', app)
}

onMounted(() => {
  document.addEventListener('click', closeContextMenu)
})

onUnmounted(() => {
  document.removeEventListener('click', closeContextMenu)
  if (longPressTimer) {
    clearTimeout(longPressTimer)
    longPressTimer = null
  }
  if (cleanupPointerTracking) {
    cleanupPointerTracking()
    cleanupPointerTracking = null
  }
})

// Input handled by v-bng-text-input directive
</script>

<style scoped lang="scss">
.phone-search {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding: 52px 0 8px;
}

.search-input-wrap {
  display: flex;
  align-items: center;
  background: rgba(255, 255, 255, 0.12);
  border-radius: 999px;
  width: min(100%, 300px);
  align-self: center;
  padding: 7px 12px;
  margin: 0 auto 12px;
}

.search-icon-svg {
  margin-right: 8px;
  opacity: 0.6;
  color: rgba(255, 255, 255, 0.8);
  flex-shrink: 0;
}

.search-input {
  flex: 1;
  background: none;
  border: none;
  outline: none;
  color: white;
  font-size: 14px;
  font-family: inherit;

  &::placeholder {
    color: rgba(255, 255, 255, 0.45);
  }
}

.search-results {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 2px;

  &::-webkit-scrollbar {
    width: 4px;
  }
  &::-webkit-scrollbar-track {
    background: transparent;
  }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.25);
    border-radius: 2px;
  }
  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.4);
  }
}

.search-result-item {
  display: flex;
  align-items: center;
  padding: 8px;
  border-radius: 12px;
  cursor: pointer;
  transition: background 0.15s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.1);
  }
}

.search-result-icon {
  width: 44px;
  height: 44px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.6em;
  flex-shrink: 0;
  position: relative;
  overflow: hidden;

}

.search-result-icon-image {
  width: calc(100% + 1px);
  height: calc(100% + 1px);
  display: block;
  position: absolute;
  top: -0.5px;
  left: -0.5px;
  z-index: 1;
  object-position: center;
  backface-visibility: hidden;
  transform: translateZ(0);
}

.search-result-icon-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(to bottom, transparent, rgba(0, 0, 0, 0.35));
  pointer-events: none;
}

.search-result-info {
  margin-left: 12px;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-width: 0;
}

.search-result-name {
  color: white;
  font-size: 14px;
  font-weight: 500;
}

.search-result-category {
  color: rgba(255, 255, 255, 0.5);
  font-size: 11px;
  margin-top: 1px;
}

.search-result-new {
  background: #ff3b30;
  color: white;
  font-size: 8px;
  font-weight: 700;
  padding: 2px 5px;
  border-radius: 6px;
  letter-spacing: 0.5px;
}

.search-result-add-hint {
  color: rgba(255, 255, 255, 0.5);
  font-size: 9px;
  margin-left: auto;
}

.search-context-modal {
  position: fixed;
  inset: 0;
  z-index: 12000;
  background: rgba(0, 0, 0, 0.4);
}

.search-context-menu {
  position: fixed;
  z-index: 12001;
  background: rgba(40, 40, 40, 0.98);
  backdrop-filter: blur(12px);
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: 10px;
  padding: 4px;
  min-width: 140px;
  box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4);
}

.context-menu-btn {
  display: block;
  width: 100%;
  padding: 8px 12px;
  border: none;
  border-radius: 6px;
  background: none;
  color: white;
  font-size: 13px;
  text-align: left;
  cursor: pointer;
  transition: background 0.15s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.15);
  }
}
</style>
