// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { onUnmounted } from "vue"
import { lua } from "@/bridge"
import { safeLua } from "../utils/safeLua.js"

// Use on controls without v-bng-text-input, whose directive already owns CEF typing.
export function useCefTyping() {
  let focused = false
  function onFocus() {
    focused = true
    return safeLua(() => lua.setCEFTyping(true), "Enable typing for the focused control")
  }
  function onBlur() {
    focused = false
    return safeLua(() => lua.setCEFTyping(false), "Release typing for the blurred control")
  }
  function dispose() {
    if (focused) return onBlur()
  }
  onUnmounted(dispose)
  return { onFocus, onBlur, dispose }
}
