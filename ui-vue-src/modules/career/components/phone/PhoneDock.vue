<template>
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
</template>

<script setup>
import { computed } from 'vue'
import PhoneAppIcon from './PhoneAppIcon.vue'

const props = defineProps({
  dockIds: { type: Array, required: true },
  appMap: { type: Object, required: true },
  jiggleMode: { type: Boolean, default: false },
  highlightIndex: { type: Number, default: -1 },
})

const emit = defineEmits(['launch', 'longpress', 'dragstart', 'dockdrop'])

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
.phone-dock {
  position: absolute;
  bottom: 30px;
  left: 50%;
  transform: translateX(-50%);
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
  z-index: 20;
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
