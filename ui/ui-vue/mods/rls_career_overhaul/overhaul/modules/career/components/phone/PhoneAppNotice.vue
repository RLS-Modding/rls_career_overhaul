<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!--
  One phone app notice: why an app can't be used right now (locked behind a skill, unavailable while walking,
  failed to load). Plain fills the app screen; `card` is the dark card used inside an app's own overlay.
  Buttons go in the default slot; give the main one the `primary` class.
-->
<template>
  <div class="phone-app-notice" :class="{ 'phone-app-notice--card': card }" role="status">
    <span class="phone-app-notice__badge" aria-hidden="true"><BngIcon :type="icon" /></span>
    <h3 v-if="title" class="phone-app-notice__title">{{ title }}</h3>
    <p class="phone-app-notice__message">{{ message }}</p>
    <div v-if="$slots.default" class="phone-app-notice__actions"><slot /></div>
  </div>
</template>

<script setup>
import { BngIcon, icons } from "@/common/components/base"

defineProps({
  message: { type: String, required: true },
  title: { type: String, default: "" },
  icon: { type: [String, Object], default: () => icons.lockClosed },
  card: { type: Boolean, default: false },
})
</script>

<style scoped>
.phone-app-notice {
  flex: 1;
  display: grid;
  align-content: center;
  justify-items: center;
  gap: 0.6em;
  min-height: 100%;
  padding: 2em 1.5em;
  box-sizing: border-box;
  text-align: center;
  color: rgba(255, 255, 255, 0.72);
}

.phone-app-notice--card {
  flex: none;
  min-height: 0;
  width: min(100%, 18em);
  padding: 1.75em 1.5em 1.5em;
  border-radius: 1em;
  background: #1c1f26;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 32px rgba(0, 0, 0, 0.45);
}

.phone-app-notice__badge {
  display: grid;
  place-items: center;
  width: 3.6em;
  height: 3.6em;
  margin-bottom: 0.3em;
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.1);
  color: #ffb27a;
}

.phone-app-notice__badge :deep(.bng-icon) { font-size: 2.1em; }

.phone-app-notice__title {
  margin: 0;
  font-size: 1.15em;
  font-weight: 700;
  line-height: 1.3;
  color: #fff;
}

.phone-app-notice__message {
  margin: 0;
  max-width: 18em;
  line-height: 1.4;
}

.phone-app-notice__actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 0.5em;
  margin-top: 0.6em;
}

.phone-app-notice__actions :slotted(button) {
  font: inherit;
  font-weight: 600;
  line-height: 1;
  padding: 0.75em 1.4em 0.6em;
  border: 0;
  border-radius: 0.6em;
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
  cursor: pointer;
  transition: background 0.15s ease;
}

.phone-app-notice__actions :slotted(button:hover) { background: rgba(255, 255, 255, 0.16); }
.phone-app-notice__actions :slotted(button.primary) { background: var(--bng-orange-b400, #ff6600); }
.phone-app-notice__actions :slotted(button.primary:hover) { background: #ff7a1f; }
.phone-app-notice__actions :slotted(button:active) { transform: scale(0.97); }
</style>
