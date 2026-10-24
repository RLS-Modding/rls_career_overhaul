// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, onBeforeUnmount, reactive, watch } from 'vue'
import { lua } from '@/bridge'
import { safeLua } from '../utils/safeLua'

const blockers = reactive({})
export const phoneOpeningBlocked = computed(() => Object.values(blockers).some(Boolean))

// Independent owners cannot release each other's focus trap.
export function usePhoneOpeningBlocker(owner, visible) {
  const update = blocked => {
    blockers[owner] = blocked
    safeLua(() => lua.overhaul_phone_phone.setOpeningBlocked(owner, blocked), 'Update phone opening guard')
  }
  watch(visible, update, { immediate: true, flush: 'sync' })
  onBeforeUnmount(() => update(false))
  return computed(() => Object.entries(blockers).some(([key, blocked]) => key !== owner && blocked))
}
