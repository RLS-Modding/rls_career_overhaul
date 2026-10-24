// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// One clock for visible countdown consumers; no store subscribes on their behalf.
import { onScopeDispose, readonly, ref } from "vue"

const nowSeconds = ref(Math.floor(Date.now() / 1000))
const clock = readonly(nowSeconds)
let subscribers = 0
let timer

export function useNowSeconds() {
  if (subscribers++ === 0) {
    nowSeconds.value = Math.floor(Date.now() / 1000)
    timer = setInterval(() => {
      nowSeconds.value = Math.floor(Date.now() / 1000)
    }, 1000)
  }
  onScopeDispose(() => {
    if (--subscribers !== 0) return
    clearInterval(timer)
    timer = undefined
  })
  return clock
}
