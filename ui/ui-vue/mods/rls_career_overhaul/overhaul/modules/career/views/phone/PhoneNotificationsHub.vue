<template>
  <div class="phone-notification-settings" :style="accentStyle">
    <div class="settings-card">
      <button
        v-for="link in notificationLinks"
        :key="link.route"
        type="button"
        class="settings-link-row"
        @click="goTo(link.route)"
      >
        <span class="dropdown-title">{{ link.title }}</span>
        <div class="summary-meta-wrap">
          <span class="dropdown-meta">{{ link.meta }}</span>
          <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
            <rect x="3.25" y="3.25" width="13.5" height="13.5" rx="3" stroke="currentColor" stroke-width="1.4" />
            <path
              d="M7.25 12.75L12.75 7.25M12.75 7.25H9.25M12.75 7.25V10.75"
              stroke="currentColor"
              stroke-width="1.4"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </div>
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { lua } from '@/bridge'
import {
  useNotificationAccentStyle,
  usePhoneNotificationSettings,
} from '../../composables/usePhoneNotificationSettings'

const accentStyle = useNotificationAccentStyle()

const {
  appNotificationsSummaryMeta,
  lockScreenSummaryMeta,
  dndSummaryMeta,
  useNotificationSettingsLifecycle,
} = usePhoneNotificationSettings()

useNotificationSettingsLifecycle()

const notificationLinks = computed(() => [
  { route: 'phone-notification-app-settings', title: 'App notifications', meta: appNotificationsSummaryMeta.value },
  { route: 'phone-notification-lock-screen', title: 'Lock screen notifications', meta: lockScreenSummaryMeta.value },
  { route: 'phone-notification-dnd', title: 'Do not disturb', meta: dndSummaryMeta.value },
])

function goTo(name) {
  lua.extensions.ui_router.navigate(name)
}
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-settings.scss' as *;

svg {
  width: 18px;
  height: 18px;
  display: block;
}
</style>
