// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Wallet history for one screen: asks the Lua read model for the view the screen's options name,
// keeps each option set's view so switching back is instant, and reloads when Lua reports a new
// transaction (OverhaulFinancialHistoryChanged; no polling).
// `view` always belongs to the current options: a view grouped another way is never shown under
// new options, even while the new one loads or after it fails.
import { onScopeDispose, ref, shallowRef, watch } from "vue"
import { lua } from "@/bridge"
import { useEvents } from "@/services/events"
import "../utils/installLuaBridgeFallbacks.js"
import { requestFinanceView } from "../utils/walletFinance.js"

const CHANGED_EVENT = "OverhaulFinancialHistoryChanged"
// A payout often posts several rows at once; one reload covers the burst.
const CHANGE_SETTLE_MS = 120

export function useWalletHistory(options) {
  const view = shallowRef(null)
  const loading = ref(false)
  // True when the last request for the current options failed. A view may still be shown: the
  // last good one for these same options, so the screen can say it could not refresh.
  const failed = ref(false)
  const cache = new Map()
  const pending = new Map()
  const events = useEvents()
  let request = 0
  let settleTimer = null
  let disposed = false
  // Bumped when history changes, so a reply that left Lua before the change is never cached.
  let generation = 0
  const pageLoading = ref(false)
  const pageFailed = ref(false)
  const groupPending = new Set()
  let activeGroupId = null
  let pageRequest = 0
  let shownGeneration = -1
  let shownKey = null
  const canPage = () => !loading.value && shownGeneration === generation && shownKey === keyOf(options.value)

  const keyOf = value => JSON.stringify(value)

  // One Lua call per option set at a time; prefetch and load share it.
  function fetchInto(wanted) {
    const key = keyOf(wanted)
    if (!pending.has(key)) {
      const asked = generation
      const call = requestFinanceView(lua, wanted).then(result => {
        if (pending.get(key) === call) pending.delete(key)
        if (result && !disposed && asked === generation) cache.set(key, result)
        return result
      })
      pending.set(key, call)
    }
    return pending.get(key)
  }

  async function load({ keepShown = false } = {}) {
    const wanted = options.value
    const key = keyOf(wanted)
    const ticket = ++request
    const previous = keepShown ? view.value : null
    const grouped = wanted.groupBy && wanted.groupBy !== "none"
    const depth = previous ? (grouped ? previous.groups.length : previous.rows.length) : 0
    const detailDepth = previous?.groups.find(group => group.id === activeGroupId)?.rows.length || 1
    if (cache.has(key)) {
      view.value = cache.get(key)
      shownGeneration = generation
      shownKey = key
      loading.value = false
      failed.value = false
      if (activeGroupId) loadGroup(view.value.groups.find(group => group.id === activeGroupId))
      return
    }
    if (!keepShown) view.value = null
    loading.value = true
    let result = await fetchInto(wanted)
    // Keep the portion the player reached across a payout, including an open
    // card that moves into a later summary page after the new transaction.
    const requestedOffsets = new Set()
    while (result?.paging?.hasMore && ticket === request && !disposed
      && ((grouped ? result.groups.length : result.rows.length) < depth
        || (grouped && activeGroupId && !result.groups.some(group => group.id === activeGroupId)))) {
      const offset = grouped ? {groupOffset: result.paging.nextGroupOffset} : {offset: result.paging.nextOffset}
      const nextOffset = grouped ? offset.groupOffset : offset.offset
      if (!Number.isFinite(nextOffset) || requestedOffsets.has(nextOffset)) { result = null; break }
      requestedOffsets.add(nextOffset)
      const more = await requestFinanceView(lua, {...wanted, ...offset})
      if (!more) { result = null; break }
      result = {...more, rows: grouped ? [] : [...result.rows, ...more.rows],
        groups: grouped ? [...result.groups, ...more.groups] : []}
    }
    // A newer request (another tab or sort) or an unmount owns the screen now.
    if (ticket !== request || disposed) return
    loading.value = false
    failed.value = !result
    if (!result) {
      cache.delete(key)
      if (view.value) view.value = {...view.value, groups: view.value.groups.map(group => ({...group, loading: false}))}
    }
    if (result) {
      view.value = result
      cache.set(key, result)
      shownGeneration = generation
      shownKey = key
      if (activeGroupId) loadGroup(result.groups.find(group => group.id === activeGroupId), detailDepth)
    }
  }

  // Page requests are tied to the options and generation that opened them.
  // A tab change, payout or unmount cannot append an obsolete page.
  async function loadMore() {
    const current = view.value
    if (!canPage() || !current?.paging?.hasMore || pageLoading.value) return
    const wanted = options.value, key = keyOf(wanted), asked = generation
    const ticket = ++pageRequest
    pageLoading.value = true
    pageFailed.value = false
    const grouped = wanted.groupBy && wanted.groupBy !== "none"
    const page = grouped ? { groupOffset: current.paging.nextGroupOffset } : { offset: current.paging.nextOffset }
    const result = await requestFinanceView(lua, { ...wanted, ...page })
    if (ticket !== pageRequest) return
    pageLoading.value = false
    if (disposed || asked !== generation || key !== keyOf(options.value)) return
    if (!result) { pageFailed.value = true; return }
    view.value = { ...result, rows: grouped ? [] : [...view.value.rows, ...result.rows],
      groups: grouped ? [...view.value.groups, ...result.groups] : [] }
    cache.set(key, view.value)
  }

  function replaceGroup(id, update) {
    if (!view.value) return
    view.value = { ...view.value, groups: view.value.groups.map(group => group.id === id ? update(group) : group) }
    // Busy flags belong to this request, never to a view revisited after switching sorts.
    cache.set(keyOf(options.value), { ...view.value, groups: view.value.groups.map(group => ({ ...group, loading: false })) })
  }

  async function loadGroup(group, minimum = 1) {
    if (!group) return
    activeGroupId = group.id
    if (!canPage()) return
    if (!group.paging?.hasMore || group.rows.length >= minimum) return
    const wanted = options.value, key = keyOf(wanted), asked = generation
    const pendingKey = `${asked}:${key}:${group.id}`
    if (groupPending.has(pendingKey)) return
    groupPending.add(pendingKey)
    replaceGroup(group.id, value => ({ ...value, loading: true, failed: false }))
    const result = await requestFinanceView(lua, { ...wanted, groupId: group.id, offset: group.paging.nextOffset })
    groupPending.delete(pendingKey)
    if (disposed || asked !== generation || key !== keyOf(options.value)) return
    const received = result?.groups.find(value => value.id === group.id)
    replaceGroup(group.id, value => received
      ? { ...received, rows: [...value.rows, ...received.rows], loading: false, failed: false }
      : { ...value, loading: false, failed: true })
    const updated = view.value?.groups.find(value => value.id === group.id)
    if (received && received.rows.length && updated?.paging?.hasMore && updated.rows.length < minimum) {
      await loadGroup(updated, minimum)
    }
  }

  function closeGroup() { activeGroupId = null }

  // Warm the cache for options the screen is about to show (a pressed tab during its exit motion).
  function prefetch(wanted) {
    if (!cache.has(keyOf(wanted))) fetchInto(wanted)
  }

  // Try again after a failure: ask once more, keeping whatever is shown, and stop saying it failed.
  function retry() {
    failed.value = false
    return load({ keepShown: true })
  }

  // History changed: drop every cached view, but keep showing this one until its fresh copy lands.
  function invalidate() {
    generation++
    request++
    pageRequest++
    pageLoading.value = false
    pageFailed.value = false
    if (view.value) view.value = {...view.value, groups: view.value.groups.map(group => ({...group, loading: false}))}
    cache.clear()
    pending.clear()
  }

  function onChanged() {
    // Offset pages become stale as soon as a row is posted, even while reloads settle.
    invalidate()
    clearTimeout(settleTimer)
    settleTimer = setTimeout(() => { settleTimer = null; load({ keepShown: true }) }, CHANGE_SETTLE_MS)
  }

  events.on(CHANGED_EVENT, onChanged)
  // A new sort of the same grouping keeps the current rows (marked busy) until the reorder lands;
  // a new grouping never shows the old one's groups.
  watch(options, (next, previous) => {
    pageRequest++
    pageLoading.value = false
    pageFailed.value = false
    if (!previous || previous.groupBy !== next.groupBy) activeGroupId = null
    load({ keepShown: !!previous && previous.groupBy === next.groupBy })
  }, { immediate: true, deep: true })
  onScopeDispose(() => {
    disposed = true
    request++
    clearTimeout(settleTimer)
    events.off(CHANGED_EVENT, onChanged)
  })

  return { view, loading, failed, retry, prefetch, loadMore, loadGroup, closeGroup, pageLoading, pageFailed }
}
