<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div
    class="app-icon-wrapper"
    role="button"
    :aria-label="app.name"
    :aria-disabled="tutorialBlocked || isDragGhost"
    bng-nav-item
    :class="{
      jiggling: jiggleMode,
      dragging: isDragGhost,
      'app-icon-wrapper--tutorial-blocked': tutorialBlocked,
      'app-icon-wrapper--tutorial-highlight': tutorialHighlighted,
    }"
    :data-app-id="app.id"
    :data-tutorial-id="tutorialDataId || undefined"
    :style="iconStyle"
    @pointerdown="onPointerDown"
    @click.stop="onTap"
  >
    <div class="app-badge-new" v-if="isNew && !jiggleMode">NEW</div>
    <div class="app-delete-badge" v-if="jiggleMode" @pointerdown.stop @click.stop="$emit('remove', app)">&times;</div>
    <div
      class="app-icon-square"
      :class="{
        'app-icon-square-image': hasCustomImage,
        'skills-tile': isSkillsTile,
        'skills-tile--classic': isSkillsTile && isClassicTheme,
      }"
      :style="iconSquareStyle"
    >
      <div class="app-icon-overlay" v-if="showDefaultOverlay"></div>
      <img
        v-if="hasCustomImage"
        class="app-icon-custom-image"
        :src="app.iconImage"
        :alt="app.name"
        :style="{ objectFit: app.iconImageFit || 'cover' }"
        draggable="false"
        @error="onIconImageError"
      />
      <div v-else-if="isSkillsTile && isClassicTheme" class="classic-skills-glyph" aria-hidden="true">
        <span class="classic-bar classic-bar--red"></span>
        <span class="classic-bar classic-bar--green"></span>
        <span class="classic-bar classic-bar--blue"></span>
      </div>
      <BngIcon v-else class="app-icon-img" :type="app.icon" :style="{ color: app.iconColor }" />
    </div>
    <span class="app-icon-label" v-if="showLabel">{{ app.name }}</span>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { BngIcon } from '@/common/components/base'
import { useSkillsTheme } from '../../composables/useSkillsTheme'

const props = defineProps({
  app: { type: Object, required: true },
  jiggleMode: { type: Boolean, default: false },
  jiggleOffset: { type: Number, default: 0 },
  isDragGhost: { type: Boolean, default: false },
  isNew: { type: Boolean, default: false },
  showLabel: { type: Boolean, default: true },
  tutorialDataId: { type: String, default: '' },
  tutorialHighlighted: { type: Boolean, default: false },
  tutorialBlocked: { type: Boolean, default: false },
})

const emit = defineEmits(['launch', 'longpress', 'dragstart', 'remove'])
const iconImageFailed = ref(false)
const { isClassicTheme } = useSkillsTheme()

watch(() => props.app?.iconImage, () => {
  iconImageFailed.value = false
})

const iconStyle = computed(() => {
  const s = {}
  if (props.jiggleMode) {
    s['--jiggle-offset'] = props.jiggleOffset
  }
  return s
})

const hasCustomImage = computed(() => !!props.app?.iconImage && !iconImageFailed.value)
const isSkillsTile = computed(() => props.app?.iconVariant === 'skills-theme')
const showDefaultOverlay = computed(() => {
  if (!hasCustomImage.value) return true
  return !!props.app?.iconImageOverlay
})

const iconSquareStyle = computed(() => ({
  backgroundColor: hasCustomImage.value
    ? 'transparent'
    : (isSkillsTile.value && isClassicTheme.value ? '#292820' : (props.app?.color || '#222222')),
}))

function onIconImageError() {
  iconImageFailed.value = true
}

let pressTimer = null
let pressStartPos = null
let didDrag = false
let removePressListeners = null

function onPointerDown(e) {
  if (props.jiggleMode) {
    emit('dragstart', e, props.app)
    return
  }
  removePressListeners?.()
  didDrag = false
  pressStartPos = { x: e.clientX, y: e.clientY }
  pressTimer = setTimeout(() => {
    emit('longpress', props.app)
    pressTimer = null
    didDrag = true // Treat longpress as a "drag" to prevent launch
  }, 500)

  const onMove = (ev) => {
    if (pressStartPos && (Math.abs(ev.clientX - pressStartPos.x) > 8 || Math.abs(ev.clientY - pressStartPos.y) > 8)) {
      clearTimeout(pressTimer)
      pressTimer = null
      didDrag = true
    }
  }
  const onUp = () => {
    clearTimeout(pressTimer)
    pressTimer = null
    document.removeEventListener('pointermove', onMove)
    document.removeEventListener('pointerup', onUp)
    removePressListeners = null
  }
  removePressListeners = onUp
  document.addEventListener('pointermove', onMove)
  document.addEventListener('pointerup', onUp)
}

onBeforeUnmount(() => {
  if (removePressListeners) removePressListeners()
  else if (pressTimer) clearTimeout(pressTimer)
  pressTimer = null
})

function onTap() {
  if (props.jiggleMode) return
  if (props.tutorialBlocked) return
  if (didDrag) {
    didDrag = false
    return
  }
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
  // Eases the launch press (the home screen scales a pressed icon down) instead of snapping.
  transition: transform 0.12s ease-out, opacity 0.12s ease-out;

  &.jiggling {
    animation: jiggle 0.3s ease-in-out infinite;
    animation-delay: calc(var(--jiggle-offset, 0) * 0.05s);
  }

  &.dragging {
    opacity: 0.85;
    z-index: 1000;
    pointer-events: none;
  }

  &--tutorial-blocked {
    opacity: 0.35;
    pointer-events: none;
  }

  &--tutorial-highlight {
    z-index: 2;
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
  transition: transform 0.2s ease, box-shadow 0.16s ease;
  overflow: hidden;

  .app-icon-wrapper:not(.jiggling):not(.dragging) &:hover {
    transform: scale(1.08);
  }

  // Pad focus lifts the icon itself and rings its rounded shape.
  .app-icon-wrapper.focus-visible:not(.jiggling):not(.dragging) & {
    transform: scale(1.08);
    box-shadow: 0 0 0 2px #0b0b12, 0 0 0 4px var(--phone-focus-color, rgba(255, 138, 61, .9)), 0 8px 18px rgba(0, 0, 0, .45);
  }
}

// The tile's own box (icon plus label) draws no frame; the icon shows focus.
.app-icon-wrapper.focus-visible {
  outline: none !important;
  box-shadow: none !important;
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

.app-icon-custom-image {
  width: 100%;
  height: 100%;
  display: block;
  position: relative;
  z-index: 1;
}

.skills-tile {
  background: linear-gradient(145deg, #ff7a12, #bc3700) !important;
  border: 2px solid rgba(255, 179, 94, 0.72);
  box-shadow: inset 0 2px rgba(255, 255, 255, 0.28), inset 0 -3px rgba(74, 16, 0, 0.4);
}

.skills-tile .app-icon-img {
  color: #fff !important;
  filter: drop-shadow(0 2px 1px rgba(73, 19, 0, 0.7));
}

.skills-tile--classic {
  border: 3px solid #6f6854;
  border-radius: 13px;
  background:
    repeating-linear-gradient(135deg, rgba(255, 255, 255, 0.025) 0 1px, transparent 1px 5px),
    #292820 !important;
  box-shadow: 0 0 0 2px #171611, inset 2px 2px #948970, inset -3px -3px #0d0d0a;
}

.classic-skills-glyph {
  position: relative;
  z-index: 1;
  width: 42px;
  height: 42px;
  padding: 5px;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  gap: 4px;
  border: 2px solid #11110d;
  background: #1b1b16;
  box-shadow: inset 1px 1px #4c493d, 1px 1px #81775e;
}

.classic-bar {
  width: 8px;
  border: 1px solid #0b0b08;
  box-shadow: inset 1px 1px rgba(255, 255, 255, 0.28), 1px 0 #080806;
}

.classic-bar--red {
  height: 19px;
  background: linear-gradient(90deg, #8b1f1a, #e34734);
}

.classic-bar--green {
  height: 31px;
  background: linear-gradient(90deg, #2b6229, #70ad45);
}

.classic-bar--blue {
  height: 14px;
  background: linear-gradient(90deg, #283b73, #5576bf);
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
</style>
