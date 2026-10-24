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
