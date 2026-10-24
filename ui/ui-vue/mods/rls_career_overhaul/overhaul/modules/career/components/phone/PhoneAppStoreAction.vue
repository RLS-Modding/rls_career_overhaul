<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <button
    type="button"
    class="store-pill"
    :class="{ 'store-pill--get': !isInstalled && !isInstalling, 'store-pill--busy': isInstalling }"
    :disabled="isInstalling || (!isInstalled && installBusy) || (isInstalled && !app.route)"
    :aria-label="`${isInstalling ? 'Installing' : isInstalled ? (app.route ? 'Open' : 'Installed') : 'Get'} ${app.name}`"
    :aria-busy="isInstalling"
    bng-nav-item
    v-bng-on-ui-nav:ok.asMouse.focusRequired
    @click.stop="$emit('action')"
  >
    <span v-if="isInstalling" class="store-install-spinner" aria-hidden="true"></span>
    <span>{{ isInstalling ? 'Installing…' : isInstalled ? (app.route ? 'OPEN' : 'Installed') : 'GET' }}</span>
  </button>
</template>

<script setup>
import { vBngOnUiNav } from '@/common/directives'

defineProps({
  app: { type: Object, required: true },
  isInstalled: { type: Boolean, default: false },
  isInstalling: { type: Boolean, default: false },
  installBusy: { type: Boolean, default: false },
})
defineEmits(['action'])
</script>

<style scoped>
.store-pill {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  flex-shrink: 0;
  min-width: 64px;
  min-height: 34px;
  padding: 8px 12px;
  border: 0;
  border-radius: 999px;
  background: #29292f;
  color: #f8fafc;
  font-family: inherit;
  font-size: 11px;
  font-weight: 800;
  line-height: 1.2;
  letter-spacing: 0.03em;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
  transition: transform 120ms ease-out, opacity 120ms ease-out;
}
.store-pill--get { background: #f97316; color: #1c1007; }
.store-pill:hover:not(:disabled) { opacity: 0.85; }
.store-pill:active:not(:disabled) { transform: scale(0.97); }
.store-pill:disabled { cursor: default; opacity: 0.55; }
.store-pill--busy:disabled { opacity: 1; font-size: 11px; letter-spacing: 0; }
.store-install-spinner {
  width: 10px;
  height: 10px;
  border: 2px solid #62626e;
  border-top-color: #f8fafc;
  border-radius: 50%;
  animation: store-install-spin 800ms linear infinite;
}
@keyframes store-install-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .store-pill:active:not(:disabled) { transform: none; opacity: 0.7; }
  .store-install-spinner { animation: none; }
}
</style>
