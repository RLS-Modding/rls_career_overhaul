// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Owns map geometry and pointer interaction for a phone view. The caller keeps
// selection, map visibility, minimap ownership and DOM-layer mounting together.
// Read state, geometry, animation, then pointer handlers; stopMapFocusAnimation
// must be called when the owning view unmounts.
import { ref, reactive } from 'vue'

const MAP_FOCUS_DURATION_MS = 320
const DRAG_CLICK_SUPPRESS_MS = 120

export function parseViewBox(viewBoxString) {
  const raw = (viewBoxString || '0 0 1000 1000').split(' ').map(Number)
  if (raw.length !== 4 || raw.some(Number.isNaN)) return { x: 0, y: 0, w: 1000, h: 1000 }
  return { x: raw[0], y: raw[1], w: raw[2], h: raw[3] }
}

function worldToPixelDist(dxWorld, dyWorld, viewBox, containerW, containerH) {
  return Math.hypot(dxWorld * (containerW / viewBox.w), dyWorld * (containerH / viewBox.h))
}

// Clusters expand transitively in source order; duplicate keys identify one marker.
export function clusterPhoneMapItems(items, viewBoxStr, containerSize, { keyOf, xOf, yOf, radiusPx }) {
  const result = []
  const assigned = new Set()
  const box = parseViewBox(viewBoxStr)
  const cw = Math.max(1, containerSize.width)
  const ch = Math.max(1, containerSize.height)
  for (const item of items) {
    if (assigned.has(keyOf(item))) continue
    const cluster = [item]
    assigned.add(keyOf(item))
    let changed = true
    while (changed) {
      changed = false
      for (const other of items) {
        if (assigned.has(keyOf(other))) continue
        for (const member of cluster) {
          const distancePx = worldToPixelDist(xOf(other) - xOf(member), yOf(other) - yOf(member), box, cw, ch)
          if (distancePx <= radiusPx) {
            cluster.push(other)
            assigned.add(keyOf(other))
            changed = true
            break
          }
        }
      }
    }
    const posX = cluster.reduce((sum, member) => sum + xOf(member), 0) / cluster.length
    const posY = cluster.reduce((sum, member) => sum + yOf(member), 0) / cluster.length
    result.push({ cluster, posX, posY, count: cluster.length })
  }
  return result
}

export function usePhoneMapView({ minimapStore, ownerId }) {
  const mapContainer = ref(null)
  const markerViewBox = ref('0 0 1000 1000')
  const baseViewBox = ref('0 0 1000 1000')
  const panOffset = reactive({ x: 0, y: 0 })
  const zoomFactor = ref(1)
  const panState = reactive({ active: false, moved: false, lastX: 0, lastY: 0, pointerId: null })
  const suppressMarkerClickUntil = ref(0)
  let mapFocusAnimationFrame = null



  function buildWalkingZoomBaseViewBox() {
    const current = parseViewBox(minimapStore.viewBox)
    const centerX = current.x + current.w / 2
    const centerY = current.y + current.h / 2
    const mzf = Number(minimapStore.zoomFactor)
    const zfv = Number.isFinite(mzf) && mzf > 0 ? mzf : 3
    const radius = 50 * zfv
    return `${centerX - radius} ${centerY - radius} ${radius * 2} ${radius * 2}`
  }

  function getMapBaseViewBox() {
    if (minimapStore.viewControlledBy === ownerId) return parseViewBox(baseViewBox.value)
    return parseViewBox(minimapStore.viewBox)
  }

  function applyEffectiveViewBox() {
    const base = getMapBaseViewBox()
    const z = Math.max(0.25, Math.min(4, zoomFactor.value))
    const cx = base.x + panOffset.x + base.w / 2
    const cy = base.y + panOffset.y + base.h / 2
    const w = base.w * z
    const h = base.h * z
    const effective = `${cx - w / 2} ${cy - h / 2} ${w} ${h}`
    markerViewBox.value = effective
    minimapStore.setMapViewBox(effective)
  }

  function stopMapFocusAnimation() {
    if (mapFocusAnimationFrame != null) {
      cancelAnimationFrame(mapFocusAnimationFrame)
      mapFocusAnimationFrame = null
    }
  }

  function animateMapPanTo(targetX, targetY, durationMs = MAP_FOCUS_DURATION_MS) {
    stopMapFocusAnimation()
    const startX = panOffset.x
    const startY = panOffset.y
    const dx = targetX - startX
    const dy = targetY - startY
    if (Math.abs(dx) < 0.001 && Math.abs(dy) < 0.001) {
      panOffset.x = targetX
      panOffset.y = targetY
      applyEffectiveViewBox()
      return
    }
    if (globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches) {
      panOffset.x = targetX
      panOffset.y = targetY
      applyEffectiveViewBox()
      return
    }
    const startTime = performance.now()
    const step = (now) => {
      const t = Math.min(1, (now - startTime) / durationMs)
      const eased = 1 - Math.pow(1 - t, 3)
      panOffset.x = startX + dx * eased
      panOffset.y = startY + dy * eased
      applyEffectiveViewBox()
      if (t < 1) mapFocusAnimationFrame = requestAnimationFrame(step)
      else mapFocusAnimationFrame = null
    }
    mapFocusAnimationFrame = requestAnimationFrame(step)
  }

  function onMapWheel(event) {
    if (!mapContainer.value) return
    stopMapFocusAnimation()
    const delta = event.deltaY * 0.002
    zoomFactor.value = Math.max(0.1, Math.min(4, zoomFactor.value * (1 + delta)))
    applyEffectiveViewBox()
  }

  function onMapPointerDown(event) {
    stopMapFocusAnimation()
    panState.active = true
    panState.moved = false
    panState.lastX = event.clientX
    panState.lastY = event.clientY
    panState.pointerId = event.pointerId
  }

  function onMapPointerMove(event) {
    if (!panState.active || panState.pointerId !== event.pointerId || !mapContainer.value) return
    const dx = event.clientX - panState.lastX
    const dy = event.clientY - panState.lastY
    if (Math.abs(dx) > 2 || Math.abs(dy) > 2) panState.moved = true
    panState.lastX = event.clientX
    panState.lastY = event.clientY
    const rect = mapContainer.value.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return
    const box = parseViewBox(markerViewBox.value)
    panOffset.x -= dx * (box.w / rect.width)
    panOffset.y -= dy * (box.h / rect.height)
    applyEffectiveViewBox()
  }

  function onMapPointerUp(event) {
    if (panState.pointerId !== event.pointerId) return
    if (panState.moved) suppressMarkerClickUntil.value = Date.now() + DRAG_CLICK_SUPPRESS_MS
    panState.active = false
    panState.moved = false
    panState.pointerId = null
  }

  return {
    mapContainer, markerViewBox, baseViewBox, panOffset, zoomFactor,
    panState, suppressMarkerClickUntil,
    parseViewBox, buildWalkingZoomBaseViewBox, getMapBaseViewBox,
    applyEffectiveViewBox, stopMapFocusAnimation, animateMapPanTo,
    onMapWheel, onMapPointerDown, onMapPointerMove, onMapPointerUp,
  }
}
