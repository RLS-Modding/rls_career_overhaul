<template>
  <div class="phone-notification-settings" :style="accentStyle">
    <div class="settings-card">
      <button
        type="button"
        class="notif-row"
        :class="{ on: isLockScreenEnabled, muted: isDndActive }"
        @click="toggleLockScreenNotifications"
      >
        <span class="notif-copy">
          <span class="notif-label">Lock screen notifications</span>
          <span class="notif-desc">Show alerts on the lock screen when the phone is closed.</span>
        </span>
        <span class="notif-switch" :class="{ on: isLockScreenEnabled }">
          <span class="notif-knob"></span>
        </span>
      </button>

      <div class="setting-surface notif-pref-block">
        <span class="notif-section-label">Notification content</span>
        <div class="notif-radio-group">
          <button
            type="button"
            class="notif-radio-row"
            :class="{ selected: lockContentMode === 'show' }"
            @click="setLockScreenContentMode('show')"
          >
            <span class="notif-radio-circle" :class="{ on: lockContentMode === 'show' }"></span>
            <span class="notif-radio-label">Show content</span>
          </button>
          <button
            type="button"
            class="notif-radio-row"
            :class="{ selected: lockContentMode === 'hide' }"
            @click="setLockScreenContentMode('hide')"
          >
            <span class="notif-radio-circle" :class="{ on: lockContentMode === 'hide' }"></span>
            <span class="notif-radio-label">Hide content</span>
          </button>
        </div>
        <p class="notif-desc">Hide content shows the app name only on lock-screen alerts.</p>
      </div>

      <div class="setting-surface notif-pref-block">
        <div class="notif-pref-header">
          <span class="notif-label">Alert duration</span>
          <span class="notif-pref-value">{{ lockDisplayLabel }}s</span>
        </div>
        <p class="notif-desc">How long lock-screen alerts stay visible.</p>
        <div class="career-scrollbar-slider-wrap">
          <input
            type="range"
            v-model.number="lockDisplaySlider"
            class="career-scrollbar-slider"
            :min="NOTIFICATION_DISPLAY_MIN"
            :max="NOTIFICATION_DISPLAY_MAX"
            step="1"
            aria-label="Lock screen alert duration"
            @change="applyLockDisplaySeconds"
          />
          <div class="career-scrollbar-slider-labels">
            <span>{{ NOTIFICATION_DISPLAY_MIN }}s</span>
            <span>{{ NOTIFICATION_DISPLAY_MAX }}s</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import {
  useNotificationAccentStyle,
  usePhoneNotificationSettings,
} from '../../composables/usePhoneNotificationSettings'
import { clampNotificationDisplaySeconds } from '../../composables/usePhoneSettings'

const accentStyle = useNotificationAccentStyle()

const {
  NOTIFICATION_DISPLAY_MIN,
  NOTIFICATION_DISPLAY_MAX,
  lockDisplaySlider,
  isDndActive,
  isLockScreenEnabled,
  lockContentMode,
  toggleLockScreenNotifications,
  setLockScreenContentMode,
  applyLockDisplaySeconds,
  useNotificationSettingsLifecycle,
} = usePhoneNotificationSettings()

useNotificationSettingsLifecycle()

const lockDisplayLabel = computed(() =>
  clampNotificationDisplaySeconds(lockDisplaySlider.value)
)
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-notification-settings.scss' as *;
</style>
