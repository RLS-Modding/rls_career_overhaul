import { onMounted, onBeforeUnmount } from "vue"
import coreUi from "../utils/builtinCoreUi"
import { loadRuntimeComponent } from "../utils/runtimeComponent"
import { reportUiFailure } from "../utils/safeLua"

function componentFile(name, routes = coreUi.roots) {
  for (const route of routes) {
    if (route.name === name) return route.component
    const child = componentFile(name, route.children || [])
    if (child) return child
  }
}

// Warm the same graph navigation uses: scripts and styles only, never setup,
// mount, route readiness, profile reads or hidden screen instances. A click
// during prewarm shares loadRuntimeComponent's pending request. Failed loads
// remain retryable by normal navigation.
export function useRoutePrewarm(name, enabled = () => true) {
  let cancel = null
  let disposed = false
  onMounted(() => {
    const file = componentFile(name)
    if (!enabled() || !file || window.__bngRuntime?.isLoaded?.(file)) return
    const run = () => {
      cancel = null
      if (disposed || !enabled()) return
      loadRuntimeComponent(file).catch(error => reportUiFailure(error, `Prewarm route '${name}'`))
    }
    if (typeof window.requestIdleCallback === "function") {
      const id = window.requestIdleCallback(run, { timeout: 2000 })
      cancel = () => window.cancelIdleCallback(id)
    } else {
      const id = setTimeout(run, 0)
      cancel = () => clearTimeout(id)
    }
  })
  onBeforeUnmount(() => {
    disposed = true
    cancel?.()
    // In-flight graph work belongs to navigation too; do not invalidate it.
  })
}
