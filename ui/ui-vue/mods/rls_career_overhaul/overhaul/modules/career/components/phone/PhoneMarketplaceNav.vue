<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <nav class="marketplace-nav">
    <button
      type="button"
      class="nav-btn"
      :class="{ active: active === 'buy' }"
      @click="go('phone-marketplace')"
    >
      <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="11" cy="11" r="7" />
        <path d="M20 20l-4-4" />
      </svg>
      Buy
    </button>
    <button
      type="button"
      class="nav-btn"
      :class="{ active: active === 'sell' }"
      @click="go('phone-marketplace-sell')"
    >
      <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M4 8h16l-1.5 11H5.5L4 8z" />
        <path d="M9 8V6a3 3 0 016 0v2" />
      </svg>
      Sell
      <span v-if="unreadCount > 0" class="nav-badge">{{ unreadCount }}</span>
    </button>
  </nav>
</template>

<script setup>
import { lua } from '@/bridge'

const props = defineProps({
  /** Which tab is highlighted: 'buy' | 'sell'. */
  active: { type: String, default: 'buy' },
  unreadCount: { type: Number, default: 0 },
})

function go(routeName) {
  const target = routeName === 'phone-marketplace' ? 'buy' : 'sell'
  if (target === props.active) return
  lua.extensions.ui_router.navigate(routeName)
}
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.marketplace-nav {
  flex: none;
  display: flex;
  gap: 4px;
  padding: 7px 12px calc(12px + #{$mkt-bottom-inset});
  background: rgba(6, 8, 11, 0.9);
  border-top: 1px solid rgba(255, 255, 255, 0.07);
}

.nav-btn {
  flex: 1;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 7px;
  min-height: 38px;
  padding: 8px;
  border: none;
  border-radius: 11px;
  background: transparent;
  color: rgba(255, 255, 255, 0.45);
  font: inherit;
  font-size: 11.5px;
  font-weight: 700;
  cursor: pointer;

  &.active {
    background: rgba(126, 182, 255, 0.14);
    color: #9ec8ff;
  }
}

.nav-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 16px;
  height: 16px;
  padding: 0 4px;
  border-radius: 8px;
  background: #f44336;
  color: #fff;
  font-size: 9.5px;
  font-weight: 800;
  line-height: 16px;
}
</style>
