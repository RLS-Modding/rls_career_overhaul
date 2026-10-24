// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { inject, provide, ref } from 'vue'

const CONFIRM_KEY = Symbol('phoneMarketplaceConfirm')

export function providePhoneMarketplaceConfirm() {
  const pendingConfirm = ref(null)

  function askConfirm(message, action) {
    pendingConfirm.value = { message, action }
  }

  function cancelConfirm() {
    pendingConfirm.value = null
  }

  async function runConfirm() {
    const confirm = pendingConfirm.value
    if (!confirm) return false
    pendingConfirm.value = null
    await confirm.action()
    return true
  }

  provide(CONFIRM_KEY, { pendingConfirm, askConfirm, cancelConfirm })

  return { pendingConfirm, cancelConfirm, runConfirm }
}

export function usePhoneMarketplaceConfirm() {
  const ctx = inject(CONFIRM_KEY, null)
  if (!ctx) {
    return {
      askConfirm: () => {},
    }
  }
  return ctx
}
