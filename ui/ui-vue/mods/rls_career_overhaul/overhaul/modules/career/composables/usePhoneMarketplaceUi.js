// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'

export function usePhoneMarketplaceUi() {
  onMounted(() => {
    lua.overhaul_career_market_marketplace.setPhoneMarketplaceUiOpen(true)
  })
  onUnmounted(() => {
    lua.overhaul_career_market_marketplace.setPhoneMarketplaceUiOpen(false)
  })
}
