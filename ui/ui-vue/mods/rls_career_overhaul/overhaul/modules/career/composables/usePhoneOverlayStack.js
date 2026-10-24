// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Screen-local Back owner. Layers supply close callbacks; newest layer wins.
import { onBeforeUnmount } from "vue"
// Keep the screen registration lightweight; navigation services load only when
// a layer actually closes.
const restoreOpener = pick => import("./useScreenEntryFocus.js").then(({ returnFocusToOpener }) => returnFocusToOpener(pick))

export function createPhoneOverlayStack({ restore = restoreOpener } = {}) {
  const layers = []
  let lifetime = 0
  return {
    push(close, opener = document.activeElement) {
      const layer = { close, opener }
      const generation = lifetime
      layers.push(layer)
      let removed = false
      return () => {
        if (removed) return
        removed = true
        const index = layers.indexOf(layer)
        if (index < 0) return
        const top = index === layers.length - 1
        if (index !== -1) layers.splice(index, 1)
        if (top) restore(() => generation === lifetime ? opener : null)
      }
    },
    back() {
      const top = layers[layers.length - 1]
      if (!top) return false
      // The layer remains until its v-if/watch disposer runs. Repeated B must
      // not reach the screen while an asynchronous close is pending.
      if (!top.closing) {
        top.closing = true
        top.close()
      }
      return true
    },
    clear() { lifetime++; layers.length = 0 },
    get size() { return layers.length },
  }
}

export function usePhoneOverlayStack() {
  const stack = createPhoneOverlayStack()
  onBeforeUnmount(stack.clear)
  return stack
}
