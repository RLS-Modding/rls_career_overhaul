import { lua } from "@/bridge"
import { getLuaNamespace } from "../../utils/installLuaBridgeFallbacks"
import { safeLua } from "../../utils/safeLua.js"

// Plain helpers the business stores share. They hold no store state, so any store can import them.

/** Shows a red toast in the business computer; never throws (the game UI may not have the message hook). */
export const showErrorMessage = (message) => {
  if (!message) return
  safeLua(() => lua.ui_message(message, 5, "Business Computer", "error"), "Show the business computer error toast")
}

/** True when a job id cannot be sent to Lua (missing, empty or not a finite number). */
export const isMissingLuaJobId = (jobId) => (
  jobId === undefined ||
  jobId === null ||
  jobId === '' ||
  (typeof jobId === 'number' && !Number.isFinite(jobId))
)

/** Owner endpoints answer `true` or `[true, message]`; both shapes become `{ success, message }`. */
export const parseUpdateResult = (result) => {
  if (Array.isArray(result)) {
    const success = result[0] === true || result[0] === 'true' || result[0] === 1
    return { success, message: result[1] }
  }
  const success = result === true || result === 'true' || result === 1
  return { success, message: null }
}

/**
 * Business types name their owner in their manifest. The UI bridge owns that namespace's fallback
 * and follows root replacement, so business stores do not build a second layer of proxies.
 */
export const moduleNamed = getLuaNamespace
