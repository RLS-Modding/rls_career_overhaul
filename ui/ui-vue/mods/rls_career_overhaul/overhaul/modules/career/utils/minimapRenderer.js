// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Owns the cached road raster and mounted map surfaces. View boxes stay in world
// coordinates; only CSS transforms move the static terrain and road layers.
const SVG = 'http://www.w3.org/2000/svg'
const ROAD_PIXELS_PER_METRE = 2
const MAX_RASTER_SIDE = 4096
const MAX_RASTER_PIXELS = 4 * 1024 * 1024
const rounded = value => Math.round(value * 100) / 100
const svg = tag => document.createElementNS(SVG, tag)

const writtenStyles = new WeakMap()
function writeStyle(element, key, value) {
  let previous = writtenStyles.get(element)
  if (!previous) { previous = Object.create(null); writtenStyles.set(element, previous) }
  // CSSOM normalizes matrices and colours, so compare the values we assigned.
  if (previous[key] === value) return
  element.style[key] = value
  previous[key] = value
}
function boxParts(value) {
  const parts = value.split(' ').map(Number)
  return parts.length === 4 && parts.every(Number.isFinite) && parts[2] > 0 && parts[3] > 0 ? parts : null
}

export function createMinimapRenderer(state) {
  const { nodes, terrainTiles, roadsVersion, darkMode, showTerrainImage,
    isFreeCam, camRotation, playerId, playerPos, playerRotation, zoomFactor,
    viewBox, viewControlledBy } = state
  const roadCanvas = document.createElement('canvas')
  const views = new Set()
  let bounds = { x: 0, y: 0, w: 1, h: 1 }
  let mapKey = null, roadTheme = null, mapData = null
  let effectiveViewBox = viewBox.value
  let objects = {}

  function getDrivabilityColor(d) {
    if (darkMode.value) return d <= 0.1 ? '#5C4A3A' : d < 0.9 ? '#5C5C4A' : '#6B6B6B'
    return d <= 0.1 ? '#967864' : d < 0.9 ? '#969678' : '#DCDCDC'
  }

  function drawRoadNetwork() {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    const take = (x, y, radius = 0) => {
      x0 = Math.min(x0, x - radius); y0 = Math.min(y0, y - radius)
      x1 = Math.max(x1, x + radius); y1 = Math.max(y1, y + radius)
    }
    for (const node of Object.values(nodes.value)) take(-node.pos[0], node.pos[1], node.radius || 1)
    for (const tile of terrainTiles.value) {
      take(-tile.offset[0] - tile.size[0], tile.offset[1] - tile.size[1])
      take(-tile.offset[0], tile.offset[1])
    }
    bounds = Number.isFinite(x0) ? { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0) } : { x: 0, y: 0, w: 1, h: 1 }
    // Bound decoded memory on large levels without tying raster work to zoom.
    const density = Math.min(ROAD_PIXELS_PER_METRE, MAX_RASTER_SIDE / Math.max(bounds.w, bounds.h),
      Math.sqrt(MAX_RASTER_PIXELS / (bounds.w * bounds.h)))
    roadCanvas.width = Math.ceil(bounds.w * density)
    roadCanvas.height = Math.ceil(bounds.h * density)
    const context = roadCanvas.getContext('2d')
    const scaleX = roadCanvas.width / bounds.w, scaleY = roadCanvas.height / bounds.h
    context.setTransform(scaleX, 0, 0, scaleY, -bounds.x * scaleX, -bounds.y * scaleY)
    const links = [], seen = new Set()
    for (const [id, node] of Object.entries(nodes.value)) {
      for (const [targetId, link] of Object.entries(node.links || {})) {
        const target = nodes.value[targetId]
        if (!target || link.drivability < 0 || link.drivability > 1) continue
        const key = JSON.stringify([id, targetId].sort())
        if (seen.has(key)) continue
        seen.add(key)
        links.push({ node, target, drivability: link.drivability })
      }
    }
    // Preserve the dirt-to-paved stacking without drawing boundary links twice.
    links.sort((a, b) => a.drivability - b.drivability)
    for (const { node, target, drivability } of links) {
      context.beginPath()
      context.moveTo(-node.pos[0], node.pos[1])
      context.lineTo(-target.pos[0], target.pos[1])
      context.strokeStyle = getDrivabilityColor(drivability)
      context.lineWidth = Math.max(node.radius || 1, target.radius || 1)
      context.stroke()
    }
    roadTheme = darkMode.value
    roadsVersion.value++
    for (const view of views) view.syncMap()
  }

  function processMapData(data) {
    const key = data.level == null ? data : `${data.level}:${data.revision}`
    if (key === mapKey) return
    if (!data.nodes) return
    mapKey = key
    mapData = data
    nodes.value = data.nodes
    terrainTiles.value = Array.isArray(data.terrainTiles) ? data.terrainTiles : []
    drawRoadNetwork()
  }

  function refreshRoadNetwork() {
    if (mapData && roadTheme !== darkMode.value) drawRoadNetwork()
    for (const view of views) view.syncVisibility()
  }

  function setMapViewBox(value) {
    if (!boxParts(value)) return
    effectiveViewBox = value
    for (const view of views) if (view.follow) view.setViewBox(value)
  }

  function mountMap(host, { fit = 'meet', follow = true, showVehicles = true, roadOpacity = 1, terrainOpacity = 1 } = {}) {
    const terrain = svg('svg'), vehicles = svg('svg')
    let roads = views.size ? document.createElement('canvas') : roadCanvas
    const layers = showVehicles ? [terrain, roads, vehicles] : [terrain, roads]
    const markers = new Map()
    let currentViewBox = effectiveViewBox
    for (const layer of layers) {
      Object.assign(layer.style, { position: 'absolute', left: '0', top: '0', transformOrigin: '0 0', pointerEvents: 'none' })
      host.appendChild(layer)
    }
    terrain.style.opacity = String(terrainOpacity)
    roads.style.opacity = String(roadOpacity)
    vehicles.style.overflow = 'visible'

    function setViewBox(value) {
      const parts = boxParts(value)
      if (!parts) return
      currentViewBox = value
      const width = host.clientWidth, height = host.clientHeight
      if (!width || !height) return
      const [x, y, w, h] = parts
      const scale = Math[fit === 'slice' ? 'max' : 'min'](width / w, height / h)
      const tx = (width - w * scale) / 2 + (bounds.x - x) * scale
      const ty = (height - h * scale) / 2 + (bounds.y - y) * scale
      const transform = `matrix(${scale},0,0,${scale},${tx},${ty})`
      for (const layer of layers) writeStyle(layer, 'transform', transform)
    }
    function syncVisibility() {
      writeStyle(terrain, 'display', showTerrainImage.value ? '' : 'none')
    }
    function syncMap() {
      for (const layer of layers) {
        layer.style.width = `${bounds.w}px`; layer.style.height = `${bounds.h}px`
        if (layer !== roads) layer.setAttribute('viewBox', `${bounds.x} ${bounds.y} ${bounds.w} ${bounds.h}`)
      }
      if (roads !== roadCanvas) {
        roads.width = roadCanvas.width; roads.height = roadCanvas.height
        roads.getContext('2d').drawImage(roadCanvas, 0, 0)
      }
      while (terrain.firstChild) terrain.removeChild(terrain.firstChild)
      for (const tile of terrainTiles.value) {
        const image = svg('image')
        image.setAttribute('x', tile.offset[0]); image.setAttribute('y', -tile.offset[1])
        image.setAttribute('width', tile.size[0]); image.setAttribute('height', tile.size[1])
        image.setAttribute('transform', 'scale(-1,-1)')
        image.setAttribute('href', tile.file.startsWith('levels/') ? `/${tile.file}` : tile.file)
        terrain.appendChild(image)
      }
      syncVisibility()
      setViewBox(currentViewBox)
    }
    function syncMarkers() {
      if (!showVehicles) return
      const present = new Set()
      for (const [id, object] of Object.entries(objects)) {
        if (!Number.isFinite(object.posX) || !Number.isFinite(object.posY)) continue
        present.add(id)
        let marker = markers.get(id)
        if (!marker) {
          marker = svg('polygon')
          marker.setAttribute('points', '0,-10 -8,10 0,7 8,10')
          marker.style.stroke = '#ffffff'; marker.style.strokeWidth = '1.5px'
          markers.set(id, marker); vehicles.appendChild(marker)
        }
        writeStyle(marker, 'fill', object.isPlayer ? '#FF6600' : '#607d8b')
        const speed = Number.isFinite(object.speed) ? Math.max(0, object.speed) : 0
        const transform = `translate(${rounded(object.posX)},${rounded(object.posY)}) scale(${rounded(Math.min(3, 1 + speed * 0.5))}) rotate(${rounded(object.rot || 0)})`
        if (marker.lastTransform !== transform) {
          marker.setAttribute('transform', transform)
          marker.lastTransform = transform
        }
      }
      for (const [id, marker] of markers) if (!present.has(id)) {
        vehicles.removeChild(marker); markers.delete(id)
      }
    }
    const view = { follow, setViewBox, syncMap, syncMarkers, syncVisibility, adoptRoads() {
      const previous = roads
      host.replaceChild(roadCanvas, previous)
      roads = roadCanvas; layers[1] = roads
      Object.assign(roads.style, { position: 'absolute', left: '0', top: '0', transformOrigin: '0 0', pointerEvents: 'none', opacity: String(roadOpacity) })
      previous.width = previous.height = 1
      syncMap()
    }, dispose() {
      if (!views.delete(view)) return
      observer.disconnect()
      for (const layer of layers) if (layer.parentNode === host) host.removeChild(layer)
      if (roads === roadCanvas) {
        // Keep one cached backing store between apps; a concurrent survivor
        // no longer needs its private copy when the shared surface is free.
        views.values().next().value?.adoptRoads()
      } else {
        roads.width = roads.height = 1
      }
    } }
    const observer = new ResizeObserver(() => setViewBox(currentViewBox))
    observer.observe(host)
    views.add(view); syncMap(); syncMarkers()
    return view
  }

  function processMapUpdate(data) {
    isFreeCam.value = data.isFreeCam
    camRotation.value = data.camRotationZ
    playerId.value = data.controlID
    objects = data.objects || {}
    const player = objects[playerId.value]
    if (player && Number.isFinite(player.posX) && Number.isFinite(player.posY)) {
      const x = rounded(player.posX), y = rounded(player.posY)
      if (playerPos.value.x !== x || playerPos.value.y !== y) playerPos.value = { x, y }
      if (player.isPlayer) playerRotation.value = rounded(player.rot || 0)
    }
    for (const view of views) view.syncMarkers()
    let x, y, zoom
    if (data.isFreeCam) {
      if (!data.camPosition) return
      x = data.camPosition.x; y = data.camPosition.y; zoom = 50 * zoomFactor.value
    } else {
      if (!player || !Number.isFinite(player.posX) || !Number.isFinite(player.posY)) return
      const speed = Number.isFinite(player.speed) ? Math.max(0, player.speed) : 0
      x = playerPos.value.x; y = playerPos.value.y
      zoom = Math.min(50 + speed * 3.6 * 1.5, 250) * zoomFactor.value
    }
    const parts = [x - zoom, y - zoom, zoom * 2, zoom * 2].map(rounded)
    if (parts.some(value => !Number.isFinite(value)) || parts[2] <= 0) return
    const value = parts.join(' ')
    if (viewBox.value !== value) viewBox.value = value
    if (!viewControlledBy.value) setMapViewBox(value)
  }

  return { processMapData, refreshRoadNetwork, processMapUpdate, mountMap, setMapViewBox }
}
