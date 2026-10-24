// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { safeLua } from "../../../utils/safeLua.js"

// Shared by the start selectors, story labels and travel artwork. Keep the last
// validated reply when the bridge fails, and retry only while a consumer is mounted.
const entries = shallowRef([])
const ready = ref(false)
const lastError = shallowRef(null)
let pending = null
let retryTimer = null
let retryDelay = 500
let owners = 0
let catalogEvents = null
let refreshRequested = false

function onCatalogChanged() {
  // A proxy can finish mounting while discovery still holds the old catalog.
  refreshRequested = true
  if (!pending) loadMapCatalog()
}

function validateCatalog(reply) {
  const emptyTable = reply && typeof reply === "object" && Object.keys(reply).length === 0
  if (!Array.isArray(reply) && !emptyTable) throw new Error("Invalid map catalog reply")
  const ids = new Set()
  const maps = Array.isArray(reply) ? reply : []
  for (const map of maps) {
    if (!map || typeof map.id !== "string" || !/^[\w][\w.-]*$/.test(map.id) ||
        typeof map.label !== "string" || !map.label.trim() || ids.has(map.id)) {
      throw new Error("Invalid map catalog entry")
    }
    for (const field of ["preview", "travelPreview"]) {
      if (map[field] != null && typeof map[field] !== "string") throw new Error("Invalid map preview")
    }
    if (map.startPreviews != null && (typeof map.startPreviews !== "object" ||
        Array.isArray(map.startPreviews) || Object.values(map.startPreviews).some(path => typeof path !== "string"))) {
      throw new Error("Invalid start previews")
    }
    if (map.startPolicies != null && (typeof map.startPolicies !== "object" ||
        Array.isArray(map.startPolicies) || Object.values(map.startPolicies).some(policy =>
          !policy || typeof policy.available !== "boolean" || typeof policy.locked !== "boolean"))) {
      throw new Error("Invalid map start policies")
    }
    ids.add(map.id)
  }
  return [...maps].sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: "base" }))
}

function scheduleRetry() {
  if (!owners || retryTimer !== null) return
  retryTimer = setTimeout(() => {
    retryTimer = null
    loadMapCatalog()
  }, retryDelay)
  retryTimer?.unref?.()
  retryDelay = Math.min(retryDelay * 2, 10000)
}

export function loadMapCatalog() {
  if (pending) return pending
  refreshRequested = false
  clearTimeout(retryTimer)
  retryTimer = null
  let timeout
  const request = new Promise((resolve, reject) => {
    timeout = setTimeout(() => reject(new Error("Map catalog timed out")), 10000)
    Promise.resolve(lua.overhaul_world_maps.getMapCatalog()).then(resolve, reject)
  })
  pending = request.then(reply => {
    const validated = validateCatalog(reply)
    ready.value = true
    entries.value = validated
    lastError.value = null
    retryDelay = 500
    return entries.value
  }).catch(error => {
    safeLua(() => { throw error }, "Map discovery failed; keeping previous catalog")
    lastError.value = error
    scheduleRetry()
    return entries.value
  }).finally(() => {
    clearTimeout(timeout)
    pending = null
    if (refreshRequested && owners) loadMapCatalog()
  })
  return pending
}

export function useMapCatalog() {
  const { events } = useBridge()
  onMounted(() => {
    if (owners++ === 0) {
      catalogEvents = events
      catalogEvents.on("OverhaulMapCatalogChanged", onCatalogChanged)
    }
    loadMapCatalog()
  })
  onBeforeUnmount(() => {
    owners--
    if (owners) return
    catalogEvents.off("OverhaulMapCatalogChanged", onCatalogChanged)
    catalogEvents = null
    refreshRequested = false
    clearTimeout(retryTimer)
    retryTimer = null
    retryDelay = 500
  })
  const mapLabels = computed(() => Object.fromEntries(entries.value.map(map => [map.id, map.label])))
  const defaults = computed(() => entries.value.filter(map => map.defaultStart === true))
  const defaultMap = computed(() => defaults.value.length === 1 ? defaults.value[0] : null)
  return { maps: entries, ready, lastError, mapLabels, defaultMap, loadMaps: loadMapCatalog }
}

export function useStartMaps(initialMap = null, difficulty = null) {
  const catalog = useMapCatalog()
  const startingMap = ref(initialMap)
  const mapOptions = computed(() => catalog.maps.value
    .filter(map => difficulty?.value !== "hardcore" || map.startPolicies?.hardcore?.available === true)
    .map(map => ({ value: map.id, label: map.label })))
  const startingMapPolicy = computed(() => catalog.maps.value.find(map => map.id === startingMap.value)
    ?.startPolicies?.[difficulty?.value] || null)
  watch(mapOptions, options => {
    if (!catalog.ready.value) return
    if (options.some(map => map.value === startingMap.value)) return
    const defaultId = catalog.defaultMap.value?.id
    startingMap.value = options.find(map => map.value === defaultId)?.value || options[0]?.value || null
  }, { immediate: true, flush: "sync" })
  return { ...catalog, mapOptions, startingMap, startingMapPolicy }
}
