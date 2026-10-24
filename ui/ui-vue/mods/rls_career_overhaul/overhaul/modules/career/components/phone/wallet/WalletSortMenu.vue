<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Pull-down sort menu anchored to its Sort button. It grows out of the button's corner on a
     critically damped spring and shrinks back into it the same way; reopening mid-close retargets
     from where it is. Reduced motion turns the movement into a short cross-fade. -->
<template>
  <PhoneLayer v-if="rendered" :key="layerKey" :label="label" :active="open" class="wallet-menu-layer" :class="{ closing: !open }" @close="emit('close')">
    <button ref="scrimRef" type="button" class="wallet-menu-scrim" tabindex="-1" bng-no-nav="true" :aria-label="`Close ${label}`" @click="emit('close')"></button>
    <div ref="panelRef" class="wallet-menu" :style="{ top: `${top}px` }">
      <p class="wallet-menu-title" aria-hidden="true">{{ label }}</p>
      <!-- The PhoneLayer dialog already carries the label. -->
      <div role="menu">
        <button v-for="option in options" :key="option.id" type="button" class="wallet-menu-item" role="menuitemradio"
          :aria-checked="option.id === modelValue" :data-fk="option.id" bng-nav-item
          :bng-scoped-nav-autofocus="option.id === modelValue ? 'true' : null" @click="choose(option.id)">
          <span>{{ option.label }}</span>
          <svg v-if="option.id === modelValue" class="wallet-menu-check" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5" /></svg>
        </button>
      </div>
    </div>
  </PhoneLayer>
</template>

<script setup>
import { nextTick, onBeforeUnmount, ref, watch } from "vue"
import PhoneLayer from "../PhoneLayer.vue"
import { createSpring } from "../../../utils/springMotion.js"
import { prefersReducedMotion } from "../../../utils/walletFinance.js"

const props = defineProps({
  open: Boolean,
  label: { type: String, default: "Sort" },
  options: { type: Array, default: () => [] },
  modelValue: { type: String, default: "" },
  top: { type: Number, default: 0 },
})
const emit = defineEmits(["close", "update:modelValue"])

const rendered = ref(false)
const layerKey = ref(0)
const panelRef = ref(null)
const scrimRef = ref(null)
const OPEN_RESPONSE = 0.34
const FADE_RESPONSE = 0.12

let reduced = false
const spring = createSpring({
  value: 0,
  response: OPEN_RESPONSE,
  damping: 1,
  onUpdate: paint,
  onRest: value => { if (value === 0 && !props.open) rendered.value = false },
})

function paint(progress) {
  const panel = panelRef.value
  if (panel) {
    panel.style.opacity = String(Math.min(1, Math.max(0, progress)))
    panel.style.transform = reduced ? "none" : `scale(${0.6 + 0.4 * progress})`
  }
  if (scrimRef.value) scrimRef.value.style.opacity = String(Math.min(1, Math.max(0, progress)))
}

watch(() => props.open, async open => {
  reduced = prefersReducedMotion()
  const response = reduced ? FADE_RESPONSE : OPEN_RESPONSE
  if (open) {
    // Back marks its stack entry closing until disposal. Reopening owns a new entry.
    layerKey.value++
    rendered.value = true
    await nextTick()
    // Closed again before the menu drew: let the close path own it.
    if (!props.open) return
    paint(spring.value)
    spring.to(1, { response })
  } else if (rendered.value) {
    spring.to(0, { response })
  }
}, { immediate: true })

function choose(id) {
  emit("update:modelValue", id)
  emit("close")
}

onBeforeUnmount(() => spring.stop())
</script>

<style scoped>
.wallet-menu-layer { position: absolute; inset: 0; z-index: 20; }
/* A closing menu can no longer be picked from while it shrinks away. */
.wallet-menu-layer.closing { pointer-events: none; }
.wallet-menu-scrim { position: absolute; inset: 0; margin: 0; padding: 0; border: 0; background: rgba(0, 0, 0, 0.32); opacity: 0; cursor: default; }
.wallet-menu {
  position: absolute;
  right: 12px;
  width: 196px;
  padding: 6px;
  border-radius: 14px;
  background: #2c2c30;
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45), inset 0 0 0 0.5px rgba(255, 255, 255, 0.12);
  transform-origin: top right;
  opacity: 0;
  will-change: transform, opacity;
}
.wallet-menu-title { margin: 4px 8px 6px; color: rgba(235, 235, 245, 0.6); font-size: 10.5px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; }
.wallet-menu-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  min-height: 34px;
  margin: 0;
  padding: 8px 10px 6px;
  border: 0;
  border-radius: 9px;
  background: transparent;
  color: #fff;
  font: inherit;
  font-size: 13px;
  font-weight: 600;
  text-align: left;
  cursor: pointer;
  transition: transform 100ms ease-out;
}
.wallet-menu-item:hover { background: rgba(255, 255, 255, 0.08); }
.wallet-menu-item:active { transform: scale(0.97); background: rgba(255, 255, 255, 0.12); }
.wallet-menu-check { width: 15px; height: 15px; fill: none; stroke: #0a84ff; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
@media (prefers-reduced-motion: reduce) {
  .wallet-menu-item:active { transform: none; }
}
</style>
