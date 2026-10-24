<template>
  <Transition name="store-sheet">
    <div v-if="app" ref="sheetRoot" class="store-sheet-root" role="dialog" aria-modal="true"
      :aria-label="`${app.name} details`" @click.self="$emit('close')" @keydown.tab="trapFocus">
      <article class="store-detail-card">
        <div class="store-detail-grabber" aria-hidden="true"></div>
        <button ref="closeButton" type="button" class="store-detail-close" aria-label="Close app details"
          bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired @click="$emit('close')">
          <span aria-hidden="true">×</span>
        </button>

        <header class="store-detail-header">
          <div class="store-detail-icon" :style="{ backgroundColor: app.iconImage ? 'transparent' : app.color }">
            <img v-if="app.iconImage" class="store-detail-icon-image" :src="app.iconImage" alt="" draggable="false" />
            <BngIcon v-else :type="app.icon" :style="{ color: app.iconColor }" />
          </div>
          <div class="store-detail-heading">
            <p v-if="app.category" class="store-detail-category">{{ app.category }}</p>
            <h3 class="store-detail-name">{{ app.name }}</h3>
            <p v-if="app.storeTagline" class="store-detail-tagline">{{ app.storeTagline }}</p>
          </div>
        </header>

        <div class="store-detail-actions">
          <PhoneAppStoreAction :app="app" :is-installed="isInstalled" :is-installing="isInstalling"
            :install-busy="installBusy" @action="$emit(isInstalled ? 'open' : 'install')" />
          <button v-if="isInstalled && !isInstalling" type="button" class="store-detail-uninstall"
            :disabled="installBusy" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
            @click="$emit('uninstall')">Uninstall</button>
        </div>

        <div class="store-detail-body" bng-nav-scroll aria-label="About this app">
          <h4 class="store-detail-label">About this app</h4>
          <p class="store-detail-description">{{ app.storeDescription }}</p>
          <p v-if="app.isUsageUnlocked === false" class="store-detail-locked">
            <strong>Unlock required</strong>
            {{ app.lockedMessage || 'Install now. This app becomes available as you progress.' }}
          </p>
        </div>
      </article>
    </div>
  </Transition>
</template>

<script setup>
import { nextTick, ref, watch } from 'vue'
import { BngIcon } from '@/common/components/base'
import { vBngOnUiNav } from '@/common/directives'
import PhoneAppStoreAction from './PhoneAppStoreAction.vue'

const props = defineProps({
  app: { type: Object, default: null },
  isInstalled: { type: Boolean, default: false },
  isInstalling: { type: Boolean, default: false },
  installBusy: { type: Boolean, default: false },
})

defineEmits(['close', 'install', 'uninstall', 'open'])
const closeButton = ref(null)
const sheetRoot = ref(null)

watch(() => props.app, async app => {
  if (!app) return
  await nextTick()
  // Focusing inside the off-screen card would scroll the phone to reveal it mid-slide.
  if (props.app === app) closeButton.value?.focus({ preventScroll: true })
}, { immediate: true })

function trapFocus(event) {
  const items = [...(sheetRoot.value?.querySelectorAll('button:not(:disabled), [tabindex="0"]') || [])]
  const first = items[0]
  const last = items[items.length - 1]
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault()
    last?.focus({ preventScroll: true })
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault()
    first?.focus({ preventScroll: true })
  }
}
</script>

<style scoped>
.store-sheet-root {
  position: absolute;
  inset: 0;
  z-index: 30;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding: 96px 8px 8px;
  background: rgba(0, 0, 0, 0.64);
}
.store-detail-card {
  position: relative;
  width: 100%;
  max-height: 100%;
  display: flex;
  flex-direction: column;
  border-radius: 24px 24px 20px 20px;
  border: 1px solid #393940;
  background: #19191f;
  overflow: hidden;
  color: #f8fafc;
}
.store-detail-grabber { width: 32px; height: 4px; border-radius: 999px; margin: 10px auto 20px; background: #62626e; flex-shrink: 0; }
.store-detail-close { position: absolute; top: 14px; right: 12px; display: flex; align-items: center; justify-content: center; width: 30px; height: 30px; border: 0; border-radius: 50%; background: #303038; color: #c6c6d0; font-size: 22px; cursor: pointer; }
.store-detail-header { display: flex; align-items: center; gap: 12px; padding: 0 18px; margin-top: 8px; flex-shrink: 0; }
.store-detail-icon { width: 64px; height: 64px; border-radius: 16px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; overflow: hidden; font-size: 36px; }
.store-detail-icon-image { width: 100%; height: 100%; object-fit: cover; display: block; }
.store-detail-heading { min-width: 0; }
.store-detail-category { margin: 0 0 4px; color: #a6a6b2; font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }
.store-detail-name { margin: 0; font-size: 21px; line-height: 1.15; font-weight: 800; letter-spacing: -0.025em; overflow-wrap: anywhere; }
.store-detail-tagline { margin: 5px 0 0; font-size: 12px; line-height: 1.4; color: #a6a6b2; }
.store-detail-actions { display: flex; align-items: center; gap: 12px; padding: 20px 18px; flex-shrink: 0; }
.store-detail-actions :deep(.store-pill) { min-height: 40px; min-width: 96px; font-size: 12px; }
.store-detail-uninstall { min-height: 40px; padding: 8px 12px; border: 0; border-radius: 999px; background: transparent; color: #a6a6b2; font: inherit; font-size: 12px; cursor: pointer; }
.store-detail-uninstall:hover, .store-detail-uninstall.focus-visible { color: #fca5a5; background: #3b2429; }
.store-detail-uninstall:disabled { opacity: 0.55; cursor: default; }
.store-detail-body { min-height: 0; overflow-y: auto; padding: 18px 18px 24px; border-top: 1px solid #34343d; scrollbar-width: thin; }
.store-detail-label { margin: 0 0 8px; font-size: 14px; font-weight: 700; letter-spacing: -0.01em; }
.store-detail-description { margin: 0; font-size: 12px; line-height: 1.6; color: #c6c6d0; overflow-wrap: anywhere; }
.store-detail-locked { margin: 16px 0 0; padding: 12px; border-radius: 12px; background: #342a1e; font-size: 11px; line-height: 1.5; color: #e7bc75; }
.store-detail-locked strong { display: block; margin-bottom: 4px; font-weight: 700; }
.store-detail-card button { transition: transform 120ms ease-out; }
.store-detail-card button:active:not(:disabled) { transform: scale(0.97); }
.store-sheet-enter-active { transition: opacity 320ms ease-out; }
.store-sheet-leave-active { transition: opacity 260ms ease-in; }
.store-sheet-enter-active .store-detail-card { transition: transform 380ms cubic-bezier(0.32, 0.72, 0, 1); }
.store-sheet-leave-active .store-detail-card { transition: transform 260ms cubic-bezier(0.4, 0, 1, 1); }
.store-sheet-enter-from, .store-sheet-leave-to { opacity: 0; }
.store-sheet-enter-from .store-detail-card, .store-sheet-leave-to .store-detail-card { transform: translateY(100%); }
@media (prefers-reduced-motion: reduce) {
  .store-sheet-enter-from .store-detail-card, .store-sheet-leave-to .store-detail-card { transform: none; }
  .store-detail-card button:active:not(:disabled) { transform: none; opacity: 0.7; }
}
</style>
