const reportedContexts = new Set()

export function reportUiFailure(error, why) {
  if (!reportedContexts.has(why)) {
    reportedContexts.add(why)
    console.warn(`[Overhaul] ${why}`, error)
  }
  return undefined
}

// Optional UI calls may fail while their Lua owner unloads. Keep that context visible without flooding the console.
export function safeLua(callOrPromise, why) {
  const failed = error => reportUiFailure(error, why)
  try {
    const result = typeof callOrPromise === "function" ? callOrPromise() : callOrPromise
    return result && typeof result.then === "function" ? Promise.resolve(result).catch(failed) : result
  } catch (error) {
    return failed(error)
  }
}
