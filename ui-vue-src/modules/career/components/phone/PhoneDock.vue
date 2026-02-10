<template>
  <div class="phone-dock-area">
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
    <div class="phone-dock" @pointerup="onDockPointerUp">
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
            />
          </div>
        </template>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import PhoneAppIcon from './PhoneAppIcon.vue'

const props = defineProps({
  dockIds: { type: Array, required: true },
  appMap: { type: Object, required: true },
  jiggleMode: { type: Boolean, default: false },
  highlightIndex: { type: Number, default: -1 },
  totalPages: { type: Number, default: 0 },
  currentPage: { type: Number, default: 0 },
  isSearchActive: { type: Boolean, default: false },
})

const emit = defineEmits(['launch', 'longpress', 'dragstart', 'dockdrop', 'goPage'])

const dockApps = computed(() => {
  return props.dockIds.map(id => id ? props.appMap[id] || null : null)
})

function onIconPointerDown(e, app, idx) {
  if (props.jiggleMode) {
    emit('dragstart', e, app, 'dock', idx)
  }
}

function onDockPointerUp() {
  // handled by parent drag system
}
</script>

<style scoped lang="scss">
.phone-dock-area {
  position: absolute;
  bottom: 24px;
  left: 0;
  right: 0;
  z-index: 20;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  transition: transform 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94);
}

.phone-dock-area.no-transition {
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
    background: rgba(255, 255, 255, 0.9);
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
  background: rgba(20, 20, 20, 0.55);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 30px;
  box-sizing: border-box;
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

  &.dock-slot-highlight {
    background: rgba(255, 255, 255, 0.15);
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
