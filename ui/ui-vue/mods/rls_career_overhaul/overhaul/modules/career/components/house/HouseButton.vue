<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Style Guide button (.btn and its variants) with the game's controller focus and click sound.
     Hold-to-confirm: put v-bng-click="{ holdCallback, holdDelay }" on it as with BngButton; the
     hold-start / hold-active classes that directive sets drive the fill. -->
<template>
  <button
    type="button"
    class="rls-house btn house-button"
    :class="[variantClass, { compact, block, 'icon-only': icon && !$slots.default }]"
    :disabled="disabled"
    :tabindex="tabindex"
    v-bind="navAttrs"
    v-bng-sound-class="!disabled && 'bng_click_hover_generic'">
    <span class="hold-fill" aria-hidden="true"></span>
    <BngBinding v-if="binding" class="btn-binding" :ui-event="binding" controller track-ignore />
    <BngIcon v-if="icon" class="btn-icon" :type="icon" />
    <span v-if="$slots.default" class="btn-label"><slot /></span>
  </button>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, BngBinding } from "@/common/components/base"
import { vBngSoundClass } from "@/common/directives"

const props = defineProps({
  // neutral | primary | quiet | quiet-danger | danger | text | menu (full-width left-aligned menu row)
  variant: { type: String, default: "neutral" },
  compact: Boolean,
  block: Boolean,
  disabled: Boolean,
  icon: [String, Object],
  navItem: { type: Boolean, default: true },
  tabindex: { type: Number, default: 0 },
  // controller glyph shown before the label when a pad is in use (e.g. "ok", "back", "context")
  binding: String,
})

// Disabled buttons leave controller navigation: the game's crossfire would still step onto them,
// fail to focus, and strand the d-pad (seen on the maintenance cart's Confirm).
const navAttrs = computed(() => {
  // navItem false = out of controller navigation entirely: the game's native navigation also picks up
  // plain <button>s, so leaving out bng-nav-item alone is not enough
  if (!props.navItem) return { "bng-no-nav": "true" }
  return props.disabled ? { "bng-nav-item": "", "bng-no-nav": "true" } : { "bng-nav-item": "" }
})

const variantClass = computed(() => (props.variant === "neutral" ? null : `btn-${props.variant}`))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.house-button {
  position: relative;
  flex-shrink: 0; // keep the label readable: a squeezed flex row should not turn "Save" into "Sa…"
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.45em;
  overflow: hidden;
  isolation: isolate;
  &.block {
    display: flex;
    width: 100%;
  }
  &.icon-only {
    padding-left: 0.75em;
    padding-right: 0.75em;
  }
}
.btn-icon {
  flex: 0 0 auto;
  font-size: 1.15em;
  line-height: 1;
  transform: translateY(-0.05em);
}
.btn-binding {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  margin-left: -0.15em;
}
.btn-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  // room for descenders ("g", "y") inside the clip box without changing the button's height
  padding-bottom: 0.15em;
  margin-bottom: -0.15em;
}

/* menu row (Style Guide .menu-item): full width, left aligned, quiet until hovered/focused */
.house-button.btn-menu {
  display: flex;
  width: 100%;
  justify-content: flex-start;
  padding: 0.62em 0.75em 0.48em;
  border-radius: var(--radius-thumb);
  background: transparent;
  color: #fff;
  font-weight: 600;
  text-align: left;
  &:hover:not(:disabled),
  &.focus-visible {
    background: rgba(255, 255, 255, 0.07);
    box-shadow: none;
  }
  // controller: menu rows show the inset ring as well as the lift
  &.focus-visible {
    box-shadow: var(--focus-inset);
  }
  &:disabled {
    opacity: 0.4;
  }
  .btn-label {
    flex: 1 1 auto;
    display: flex;
    align-items: baseline;
    gap: 0.4em;
    white-space: normal;
  }
}

/* hold-to-confirm fill (classes and --hold-time come from v-bng-click) */
.hold-fill {
  position: absolute;
  inset: 0;
  z-index: -1;
  background: rgba(255, 255, 255, 0.22);
  transform: scaleX(0);
  transform-origin: left center;
  pointer-events: none;
}
.house-button.hold-active .hold-fill {
  transform: scaleX(1);
  transition: transform var(--hold-time, 1s) linear;
}
.house-button.hold-completed .hold-fill {
  transform: scaleX(1);
  opacity: 0;
  transition: opacity 0.2s ease-out;
}
</style>
