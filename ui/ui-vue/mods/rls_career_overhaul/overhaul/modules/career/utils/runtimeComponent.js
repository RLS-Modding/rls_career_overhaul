// Runtime loading owns graph requests and stable component identities per file/host.
// Read shared loading, overlay wrappers, pending screens, then lazy route preparation.
// The graph owns resolved modules; recovery retires requests at both cache owners.
import { defineAsyncComponent, markRaw, defineComponent, shallowRef, h, onUnmounted } from 'vue'
import { loadModule } from '@/services/uiMods'
import { reportUiFailure } from './safeLua'

// The Vue debug overlay unloads this mod's directory before re-evaluating its
// entry point, so module-local wrappers are replaced when the mod reloads.
const components = new Map()
const pendingModules = new Map()
const latestModules = new Map()
const routeComponents = new Map()
const hostComponents = new Map()
const LOAD_TIMEOUT_MS = 20000

function retireRejectedRuntimeModules() {
  // BeamNG 0.40's graph retains rejected Loading records, including children
  // of a failed root. Retire only those failures; a directory unload would
  // remove styles from healthy mounted siblings. Do not await unrelated work.
  const cache = window.__rtModules
  if (!cache) return
  for (const [id, entry] of Object.entries(cache)) {
    // The shipped bundle minifies Loading's class name. Its record shape is
    // stable: a class instance containing only promise and optional partial.
    if (!entry || Object.getPrototypeOf(entry) === Object.prototype ||
        typeof entry.promise?.catch !== 'function' ||
        Object.keys(entry).some(key => key !== 'promise' && key !== 'partial')) continue
    entry.promise.catch(() => {
      // A retry/reload can already have replaced this exact request.
      if (cache[id] === entry) window.__bngRuntime.invalidate(id)
    })
  }
}

function invalidateModule(file) {
  // Invalidating one record preserves styles owned by mounted sibling screens.
  const runtime = window.__bngRuntime
  runtime.invalidate(runtime.resolve(undefined, file))
}

export function resetRuntimeComponent(file, pending) {
  const entry = pendingModules.get(file)
  if (!entry || entry.promise !== pending) return
  entry.retired = true
  pendingModules.delete(file)
  invalidateModule(file)
}

export function loadRuntimeComponent(file) {
  if (!pendingModules.has(file)) {
    const entry = { promise: null, retired: false, resolved: false }
    latestModules.set(file, entry)
    entry.promise = Promise.resolve().then(() => loadModule(file)).then(module => {
      // The graph can publish a retired request after recovery. Invalidating it
      // also removes this file's styles, including those of a successful retry.
      if (entry.retired && !latestModules.get(file)?.resolved) invalidateModule(file)
      const component = module?.default
      if (!component || (typeof component !== 'object' && typeof component !== 'function')) {
        throw new Error('missing default component export')
      }
      entry.resolved = !entry.retired
      return markRaw(component)
    }).catch(error => {
      retireRejectedRuntimeModules()
      resetRuntimeComponent(file, entry.promise)
      throw new Error(`Could not load ${file}: ${error?.message || error}`, { cause: error })
    }).finally(() => {
      // An old completion must not retire a newer recovery attempt.
      if (pendingModules.get(file) === entry) pendingModules.delete(file)
    })
    pendingModules.set(file, entry)
  }
  return pendingModules.get(file).promise
}

// Overlay owners and business tabs keep async wrappers; routes use runtimeRouteComponent.
export function runtimeComponent(file) {
  if (!components.has(file)) components.set(file, defineAsyncComponent(() => loadRuntimeComponent(file)))
  return components.get(file)
}

function boundedLoad(file) {
  const pending = loadRuntimeComponent(file)
  let timer
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      resetRuntimeComponent(file, pending)
      reject(new Error(`Could not load ${file}: timed out`))
    }, LOAD_TIMEOUT_MS)
  })
  return Promise.race([pending, deadline]).finally(() => clearTimeout(timer))
}

function pendingScreen(file, firstLoad, { phone = true, preload = firstLoad } = {}) {
  let loaded
  // A cancelled cold visit can resolve before this wrapper ever mounts.
  preload?.then(component => { loaded ||= component }, () => {})
  const PendingScreen = defineComponent({
    name: phone ? 'PhonePendingScreen' : 'RoutePendingScreen',
    inheritAttrs: false,
    // Router sees this stable presentation, so preserve hosted preparation.
    beforeRouteEnter(to, from, next) {
      const guard = loaded?.beforeRouteEnter
      if (!guard) return next()
      if (guard.length >= 3) return guard(to, from, next)
      return Promise.resolve(guard(to, from)).then(next)
    },
    beforeRouteUpdate(to, from) { return loaded?.beforeRouteUpdate?.(to, from) },
    setup(_, { attrs }) {
      const component = shallowRef(loaded)
      const failed = shallowRef(false)
      let generation = 0
      async function retry(pending = boundedLoad(file)) {
        const token = ++generation
        failed.value = false
        try {
          const resolved = await pending
          if (token !== generation) return
          loaded = resolved
          component.value = loaded
        } catch (error) {
          if (token !== generation) return
          failed.value = true
          reportUiFailure(error, `Load route screen '${file}'`)
        }
      }
      const initial = firstLoad
      firstLoad = null
      if (!loaded) retry(initial || boundedLoad(file))
      onUnmounted(() => {
        generation++
      })
      return () => {
        if (component.value) return h(component.value, attrs)
        if (!phone) return h('div') // Keep the world visible while loading.
        return h('div', {
          class: 'phone-screen-loading', role: 'status',
          style: 'height:100%;background:#15171d;color:white;display:grid;place-content:center;text-align:center;padding:2em;box-sizing:border-box',
        }, failed.value ? [h('p', 'This screen could not be loaded.'),
          h('button', { onClick: () => retry() }, 'Try again')] : [h('span', { 'aria-hidden': 'true' }, '◌'), h('p', 'Loading…')])
      }
    },
  })
  return markRaw(PendingScreen)
}

// Parent routes await their full deadline. Only a terminal failure commits a
// retry page; its identity then stays stable through recovery and tree rebuilds.
export function runtimeHostComponent(file) {
  if (!hostComponents.has(file)) {
    let resolved
    hostComponents.set(file, () => {
      if (!resolved) resolved = boundedLoad(file).catch(error => {
        const failed = Promise.reject(error)
        failed.catch(() => {}) // A cancelled navigation may never mount the error page.
        return pendingScreen(file, failed, { phone: true })
      })
      return resolved
    })
  }
  return hostComponents.get(file)
}

// Route records use a bare lazy function. Vue Router awaits it before
// committing. Slow imports retain the current screen until guards can run.
export function runtimeRouteComponent(file, { phone = true } = {}) {
  if (!routeComponents.has(file)) routeComponents.set(file, new Map())
  const variants = routeComponents.get(file)
  if (!variants.has(phone)) {
    // Cache the first presentation as well as the loader: sibling records must
    // retain the same tree after a cold load, or screen teardown cancels work.
    let presentation
    const prepare = async () => {
      try {
        // Router must invoke the real guard in its injection context, after
        // import completes and before navigation commits.
        return await boundedLoad(file)
      } catch {
        return pendingScreen(file, null, { phone })
      }
    }
    variants.set(phone, () => presentation ||= prepare())
  }
  return variants.get(phone)
}
