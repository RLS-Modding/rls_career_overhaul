<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- League promo / milestone panel for the racing team, house style. Image first, then the title
     (biggest), body text, the registration fee in gold and the slotted actions on the right.
     variant "modal": near-black house modal card, shown inside .rt-promo-overlay (teleported to body
     by BusinessComputerMain and RacingTeamMilestoneSplash). variant "card": a plain panel inside a tab. -->
<template>
  <div :class="['rls-house', 'rt-promo-panel', variant === 'card' ? 'rt-promo-panel--card' : 'rt-promo-panel--modal']" @click.stop>
    <img v-if="imageUrl" class="rt-promo-panel__img" :src="imageUrl" alt="" />
    <div class="rt-promo-panel__copy">
      <h2 v-if="title" :class="variant === 'card' ? 'rt-promo-panel__title rt-promo-panel__title--card' : 'rt-promo-panel__title'">
        {{ title }}
      </h2>
      <p v-if="body" class="rt-promo-panel__body">{{ body }}</p>
      <p v-if="feeDisplay" class="rt-promo-panel__fee">
        <span class="rt-promo-panel__fee-key">Registration fee</span>
        <span class="rt-promo-panel__fee-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ feeDisplay }}</span>
      </p>
    </div>
    <div v-if="$slots.default" class="rt-promo-panel__actions">
      <slot />
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { BngIcon, icons } from "@/common/components/base"

const props = defineProps({
  title: { type: String, default: "" },
  body: { type: String, default: "" },
  imageUrl: { type: String, default: "" },
  fee: { type: [Number, String], default: null },
  variant: { type: String, default: "modal" },
})

const feeDisplay = computed(() => {
  if (props.fee === null || props.fee === undefined || props.fee === "") return ""
  const n = Number(props.fee)
  return Number.isFinite(n) ? n.toLocaleString() : ""
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.rt-promo-panel {
  display: grid;
  gap: var(--space-3);
  min-width: 0;
}

/* modal: house modal card (the overlay around it carries the em scale) */
.rt-promo-panel--modal {
  width: min(32em, calc(100vw - 2em));
  max-height: calc(100vh - 2em);
  overflow-y: auto;
  padding: var(--inset);
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  // no scrollbar-width / scrollbar-color: in Chromium 121+ they override the ::-webkit-scrollbar styling
  // below and draw the native bar with arrow buttons

  &::-webkit-scrollbar { width: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
}

/* card: one panel in the tab, no ring */
.rt-promo-panel--card {
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.rt-promo-panel__img {
  display: block;
  width: 100%;
  max-height: 14em;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  background: var(--photo);
  object-fit: cover;
}

.rt-promo-panel--card .rt-promo-panel__img {
  max-height: 11em;
}

.rt-promo-panel__copy {
  display: grid;
  gap: 0.45em;
  min-width: 0;
}

.rt-promo-panel__title {
  margin: 0;
  color: #fff;
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}

.rt-promo-panel__title--card {
  font-size: 1.15em;
}

.rt-promo-panel__body {
  margin: 0;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.45;
  white-space: pre-wrap;
}

.rt-promo-panel__fee {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 0.2em 0.6em;
  margin: 0.15em 0 0;
}

.rt-promo-panel__fee-key {
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}

.rt-promo-panel__fee-value {
  color: var(--money);
  font-size: 1.05em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}

.rt-promo-panel__actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: var(--space-2);
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

<style lang="scss">
// Unscoped: the overlay and fade live in BusinessComputerMain / RacingTeamMilestoneSplash markup.
.rt-promo-overlay {
  position: fixed;
  inset: 0;
  z-index: 13060;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 1em;
  background: rgba(0, 0, 0, 0.6);
  pointer-events: auto;
  // teleported to body: carry the business computer em scale
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
}

// Plain .btn buttons slotted in by RacingTeamMilestoneSplash get the house button look.
// HouseButton (also class btn) keeps its own kit, hence :not(.house-button).
.rt-promo-overlay .btn:not(.house-button),
.rt-promo-panel .btn:not(.house-button) {
  appearance: none;
  margin: 0;
  padding: 0.72em 1.2em 0.58em;
  border: 0;
  border-radius: 0.6em;
  font: inherit;
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.01em;
  color: #fff;
  background: rgba(255, 255, 255, 0.1);
  white-space: nowrap;
  cursor: pointer;
  transition: background-color 0.12s, transform 0.08s;

  &:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.18);
  }

  &:active:not(:disabled) {
    transform: translateY(1px);
  }

  // Controller (.focus-visible) and keyboard focus: the house ring (rlsHouse --focus values; this block
  // is unscoped, so no house tokens), on a positioned button with the game's ::before frame hidden
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600),
      0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
  }
  &.focus-visible::before {
    display: none !important;
  }

  &:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .btn-glyph {
    margin-right: 0.35em;
    vertical-align: middle;
  }
}

.rt-promo-overlay .btn-primary:not(.house-button),
.rt-promo-panel .btn-primary:not(.house-button) {
  background: #ff6600;

  &:hover:not(:disabled) {
    background: #ff7a1f;
  }

  &:disabled {
    background: #ff6600;
  }
}

.rt-promo-overlay .btn-secondary:not(.house-button),
.rt-promo-panel .btn-secondary:not(.house-button) {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}

.rt-promo-fade-enter-active,
.rt-promo-fade-leave-active {
  transition: opacity 0.2s ease;

  .rt-promo-panel {
    transition: transform 0.2s ease, opacity 0.2s ease;
  }
}

.rt-promo-fade-enter-from,
.rt-promo-fade-leave-to {
  opacity: 0;

  .rt-promo-panel {
    transform: scale(0.96);
    opacity: 0;
  }
}
</style>
