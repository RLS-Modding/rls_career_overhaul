// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Catalog state belongs to this UI, never to a Lua require-cached library. Failed replies retain
// the previous data; timeouts settle; a superseded discovery cannot publish over a newer one.
import { shallowRef } from 'vue'
import { useBridge } from '@/bridge'

const RETRY_INITIAL_MS = 500
const RETRY_MAX_MS = 10000

export function createCatalog(module, tag, builtins = []) {
  const sort = data => [...data].sort((a, b) => (a.order ?? 999) - (b.order ?? 999) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  const entries = shallowRef(sort(builtins))
  // A generated seed is valid metadata; discovery success is a separate state, even if empty.
  const ready = shallowRef(builtins.length > 0)
  const discovered = shallowRef(false)
  const lastError = shallowRef(null)
  const retryOwners = new Set()
  let retryTimer = null, retryDelayMs = RETRY_INITIAL_MS
  let pending = null, loaded = false, generation = 0
  function set(data) {
    const byId = new Map(builtins.map(entry => [entry.id, entry]))
    for (const entry of data) byId.set(entry.id, entry)
    entries.value = sort([...byId.values()])
    loaded = true
    ready.value = true
    discovered.value = true
    lastError.value = null
    retryDelayMs = RETRY_INITIAL_MS
    return entries.value
  }
  function scheduleRetry() {
    if (!retryOwners.size || retryTimer !== null) return
    retryTimer = setTimeout(() => {
      retryTimer = null
      load({ force: true }).then(data => {
        for (const onLoaded of retryOwners) onLoaded(data)
      })
    }, retryDelayMs)
    retryTimer?.unref?.()
    retryDelayMs = Math.min(retryDelayMs * 2, RETRY_MAX_MS)
  }
  function load({ force = false, timeoutMs = 10000 } = {}) {
    if (pending && !force) return pending
    clearTimeout(retryTimer)
    retryTimer = null
    const token = ++generation
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Lua discovery timed out')), timeoutMs)
      try {
        useBridge().api.engineLua(`require('${module}').listForUi()`, data => { clearTimeout(timer); resolve(data) })
      } catch (err) { clearTimeout(timer); reject(err) }
    })
    pending = reply.then(data => {
      if (token !== generation) return entries.value
      const emptyTable = data?.entries && typeof data.entries === 'object' && Object.keys(data.entries).length === 0
      if (!data || data.error || !Array.isArray(data.entries) && !emptyTable) {
        throw new Error(data?.error || 'invalid catalog reply')
      }
      for (const item of Array.isArray(data.rejected) ? data.rejected : []) console.warn(`[${tag}] ignored ${item.file}: ${item.reason}`)
      return set(Array.isArray(data.entries) ? data.entries : [])
    }).catch(err => {
      if (token === generation) {
        // Stock 0.40 makes console.error fatal while waiting for Lua to boot Angular.
        // Discovery is recoverable and must leave that bootstrap running.
        console.warn(`[${tag}] discovery failed; keeping previous data; will retry while subscribed`, err)
        lastError.value = err
        pending = null
        scheduleRetry()
      }
      return entries.value
    })
    return pending
  }
  const ensure = () => loaded && !lastError.value ? Promise.resolve(entries.value) : load()
  function retryWhileMounted(onLoaded = () => {}) {
    // Each mounting owns its subscription, even when two callers share the same callback.
    const notify = data => {
      try { onLoaded(data) } catch (err) { console.warn(`[${tag}] catalog subscriber failed`, err) }
    }
    retryOwners.add(notify)
    ensure().then(data => { if (retryOwners.has(notify)) notify(data) })
    return () => {
      retryOwners.delete(notify)
      if (retryOwners.size) return
      clearTimeout(retryTimer)
      retryTimer = null
      retryDelayMs = RETRY_INITIAL_MS
    }
  }
  return { entries, ready, discovered, lastError, set, load, ensure, retryWhileMounted }
}
