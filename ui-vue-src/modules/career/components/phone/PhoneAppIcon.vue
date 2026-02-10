<template>
  <div
    class="app-icon-wrapper"
    :class="{
      jiggling: jiggleMode,
      dragging: isDragGhost,
      launching: isLaunching,
    }"
    :style="iconStyle"
    @pointerdown.stop="onPointerDown"
    @click.stop="onTap"
  >
    <div class="app-badge-new" v-if="isNew && !jiggleMode">NEW</div>
    <div class="app-delete-badge" v-if="jiggleMode" @click.stop="$emit('remove', app)">×</div>
    <div class="app-icon-square" :style="{ backgroundColor: app.color }">
      <div class="app-icon-overlay"></div>
      <BngIcon class="app-icon-img" :type="app.icon" :style="{ color: app.iconColor }" />
    </div>
    <span class="app-icon-label" v-if="showLabel">{{ app.name }}</span>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { BngIcon } from '@/common/components/base'

const props = defineProps({
  app: { type: Object, required: true },
  jiggleMode: { type: Boolean, default: false },
  jiggleOffset: { type: Number, default: 0 },
  isDragGhost: { type: Boolean, default: false },
  isNew: { type: Boolean, default: false },
  isLaunching: { type: Boolean, default: false },
  showLabel: { type: Boolean, default: true },
  launchOrigin: { type: Object, default: null },
})

const emit = defineEmits(['launch', 'longpress', 'dragstart', 'remove'])

const iconStyle = computed(() => {
  const s = {}
  if (props.jiggleMode) {
    s['--jiggle-offset'] = props.jiggleOffset
  }
  if (props.launchOrigin) {
    s['--launch-x'] = props.launchOrigin.x + 'px'
    s['--launch-y'] = props.launchOrigin.y + 'px'
  }
  return s
})

let pressTimer = null
let pressStartPos = null

function onPointerDown(e) {
  if (props.jiggleMode) {
    emit('dragstart', e, props.app)
    return
  }
  pressStartPos = { x: e.clientX, y: e.clientY }
  pressTimer = setTimeout(() => {
    emit('longpress', props.app)
    pressTimer = null
  }, 500)

  const onMove = (ev) => {
    if (pressStartPos && (Math.abs(ev.clientX - pressStartPos.x) > 5 || Math.abs(ev.clientY - pressStartPos.y) > 5)) {
      clearTimeout(pressTimer)
      pressTimer = null
    }
  }
  const onUp = () => {
    clearTimeout(pressTimer)
    pressTimer = null
    document.removeEventListener('pointermove', onMove)
    document.removeEventListener('pointerup', onUp)
  }
  document.addEventListener('pointermove', onMove)
  document.addEventListener('pointerup', onUp)
}

function onTap() {
  if (props.jiggleMode) return
  emit('launch', props.app)
}
</script>

<style scoped lang="scss">
.app-icon-wrapper {
  display: flex;
  flex-direction: column;
  align-items: center;
  position: relative;
  cursor: pointer;
  user-select: none;

  &.jiggling {
    animation: jiggle 0.3s ease-in-out infinite;
    animation-delay: calc(var(--jiggle-offset, 0) * 0.05s);
  }

  &.dragging {
    opacity: 0.85;
    z-index: 1000;
    pointer-events: none;
  }

  &.launching .app-icon-square {
    animation: appOpen 0.3s cubic-bezier(0.2, 0.8, 0.2, 1) forwards;
  }
}

.app-icon-square {
  width: 68px;
  height: 68px;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
  transition: transform 0.2s ease;
  overflow: hidden;

  .app-icon-wrapper:not(.jiggling):not(.dragging) &:hover {
    transform: scale(1.08);
  }
}

.app-icon-overlay {
  position: absolute;
  inset: 0;
  border-radius: inherit;
  background: linear-gradient(to bottom, transparent 0%, rgba(0, 0, 0, 0.45) 100%);
  pointer-events: none;
}

.app-icon-img {
  font-size: 2.8em;
  position: relative;
  z-index: 1;
}

.app-icon-label {
  color: white;
  font-size: 11px;
  font-weight: 500;
  text-align: center;
  margin-top: 5px;
  width: 72px;
  line-height: 1.15;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.7);
}

.app-badge-new {
  position: absolute;
  top: -4px;
  right: -2px;
  background: #ff3b30;
  color: white;
  font-size: 8px;
  font-weight: 700;
  padding: 1px 5px;
  border-radius: 6px;
  z-index: 5;
  letter-spacing: 0.5px;
}

.app-delete-badge {
  position: absolute;
  top: -6px;
  left: -2px;
  width: 20px;
  height: 20px;
  background: rgba(60, 60, 60, 0.9);
  color: white;
  font-size: 14px;
  font-weight: 600;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 5;
  cursor: pointer;
  line-height: 1;
}

@keyframes jiggle {
  0%   { transform: rotate(-1.5deg) scale(1.02); }
  25%  { transform: rotate(1.5deg) scale(1.02); }
  50%  { transform: rotate(-1deg) scale(1.02); }
  75%  { transform: rotate(1deg) scale(1.02); }
  100% { transform: rotate(-1.5deg) scale(1.02); }
}

@keyframes appOpen {
  from {
    transform: scale(1);
    opacity: 1;
  }
  to {
    transform: scale(8);
    opacity: 0;
  }
}
</style>
