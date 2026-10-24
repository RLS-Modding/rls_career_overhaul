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
