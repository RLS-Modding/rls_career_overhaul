// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Save status owns only this small indicator; it never reads screen data or changes focus.
export function createSaveStatus(publish, timers = window) {
  let timeout
  let disposed = false
  const cancel = () => {
    if (timeout !== undefined) timers.clearTimeout(timeout)
    timeout = undefined
  }
  const receive = payload => {
    if (disposed) return
    const state = payload?.state
    if (!["saving", "saved", "deferred", "idle"].includes(state)) return
    cancel()
    publish(state === "idle" ? "" : state)
    if (state === "saved" || state === "deferred") {
      timeout = timers.setTimeout(() => {
        timeout = undefined
        publish("")
      }, state === "saved" ? 1800 : 3500)
    }
  }
  return { receive, dispose() { disposed = true; cancel() } }
}
