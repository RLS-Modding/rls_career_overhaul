<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Static placeholders use the strip's exact small/hero dimensions. There is
     no animation to keep running on the many cards outside its visible window. -->
<template>
  <div
    :class="['profile-loading', { 'profile-card--hero': hero, 'profile-card--selected': selected }]"
    role="status"
    aria-busy="true"
    aria-label="Loading profile">
    <div class="profile-loading-image" :style="preview ? { backgroundImage: `url('${preview}')` } : null" />
    <div class="profile-loading-body">
      <span class="profile-loading-label">{{ displayName || 'Loading profile…' }}</span>
      <span class="profile-loading-line" />
      <span class="profile-loading-line profile-loading-line--short" />
    </div>
  </div>
</template>

<script setup>
defineProps({ hero: Boolean, selected: Boolean, displayName: String, preview: String })
</script>

<style scoped lang="scss">
.profile-loading {
  overflow: hidden;
  border-radius: 12px;
  background: var(--bng-cool-gray-900, #111827);
  color: var(--bng-cool-gray-100, #f1f5f9);
  display: flex;
  flex-direction: column;
  pointer-events: none;

  &.profile-card--hero { flex-direction: row; }
}
.profile-loading-image {
  flex: 1;
  min-height: 55%;
  background-color: var(--bng-cool-gray-800, #1f2937);
  background-size: cover;
  background-position: center;
  opacity: 0.35;
}
.profile-loading-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 1em;
  padding: 1.5em;
}
.profile-loading-label { font-size: 1.2em; font-weight: 700; }
.profile-loading-line {
  display: block;
  height: 1em;
  border-radius: 4px;
  background: var(--bng-cool-gray-700, #374151);
  width: 85%;
}
.profile-loading-line--short { width: 55%; }
</style>
