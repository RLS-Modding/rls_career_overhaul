<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <!-- The auction panel's own action footer. Controller hints follow walk mode; keyboard keeps NP0. -->
  <footer class="ua-control-bar" aria-live="polite" :style="{ '--ua-hold-ms': `${holdMs}ms` }">
    <template v-if="mode === 'walk'">
      <HouseActionHint class="ua-control" :viewer-obj="backBinding" glyph-label="Back" label="Leave" />
      <span class="ua-control ua-control-hold" :class="{ holding }">
        <HouseActionHint :viewer-obj="backBinding" glyph-label="Back" label="interact" hold />
        <span class="ua-hold-track" aria-hidden="true"><span class="ua-hold-fill"></span></span>
      </span>
    </template>
    <HouseActionHint v-else-if="mode === 'panel'" class="ua-control" :viewer-obj="backBinding" glyph-label="Back" label="Walk" />
    <HouseActionHint v-else class="ua-control" ui-event="back" label="Leave auction" />
  </footer>
</template>

<script setup>
import HouseActionHint from './house/HouseActionHint.vue'

defineProps({
  // 'walk': controller released to gameplay; 'panel': controller drives the panel; 'pointer': keyboard/mouse.
  mode: { type: String, required: true },
  backBinding: Object,
  holding: Boolean,
  holdMs: { type: Number, required: true },
})
</script>

<style scoped lang="scss">
.ua-control-bar {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 0.35rem 1.1rem;
  min-height: 1.6rem;
  font-size: 0.72rem;
  font-weight: 600;
  line-height: 1;
  color: rgba(255, 255, 255, 0.78);
}

.ua-control,
.ua-control :deep(.house-action-hint) {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  white-space: nowrap;
}

.ua-control :deep(.binding-wrapper) {
  font-size: 1.15rem;
  line-height: 1;
}

.ua-control-hold {
  position: relative;
}

// Hold progress: one transform-only fill, started by the press and reset on release.
.ua-hold-track {
  position: absolute;
  left: 0;
  right: 0;
  bottom: -0.3rem;
  height: 2px;
  border-radius: 1px;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  opacity: 0;
  transition: opacity 120ms ease;
}

.ua-hold-fill {
  display: block;
  height: 100%;
  background: var(--bng-orange-b400, #ff6600);
  transform: scaleX(0);
  transform-origin: left center;
}

.holding .ua-hold-track {
  opacity: 1;
}

.holding .ua-hold-fill {
  animation: ua-hold-fill var(--ua-hold-ms) linear forwards;
}

@keyframes ua-hold-fill {
  to { transform: scaleX(1); }
}

// Reduced motion: no sweep, the bar fills in one step when the hold is long enough.
@media (prefers-reduced-motion: reduce) {
  .ua-hold-track { transition: none; }
  .holding .ua-hold-fill { animation-timing-function: steps(1, end); }
}
</style>
