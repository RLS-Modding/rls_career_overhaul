<template>
  <div class="route-map" :class="{ empty: !hasRoute }" ref="host">
    <div v-if="hasRoute" ref="mapHost" class="route-base" aria-hidden="true"></div>
    <svg v-if="hasRoute" class="route-svg" :viewBox="viewBox" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
      <g class="legs">
        <polyline v-for="(leg, i) in legs" :key="'halo' + i" class="leg-halo" :points="pts(leg.path)" :stroke-width="stroke * 2.4" />
        <polyline v-for="(leg, i) in legs" :key="'leg' + i" class="leg" :class="leg.kind" :points="pts(leg.path)" :stroke-width="stroke" :stroke-dasharray="leg.kind === 'pickup' || leg.kind === 'approach' ? `${stroke * 2} ${stroke * 1.6}` : null" />
      </g>
      <g class="markers">
        <g v-if="points.player" :transform="`translate(${-points.player[0]} ${points.player[1]})`">
          <circle r="0" />
          <polygon :points="`0,${-stroke * 2.2} ${-stroke * 1.6},${stroke * 2} 0,${stroke * 1.2} ${stroke * 1.6},${stroke * 2}`" class="player" :transform="`rotate(${playerRot})`" />
        </g>
        <g v-for="(m, i) in stopMarkers" :key="'m' + i" :transform="`translate(${-m.x} ${m.y})`">
          <circle :r="stroke * 1.9" class="stop-halo" :class="m.kind" />
          <circle :r="stroke * 1.15" class="stop" :class="m.kind" />
          <text v-if="m.label" :y="-stroke * 3" class="stop-label" :style="{ fontSize: fontSize + 'px' }" text-anchor="middle">{{ m.label }}</text>
        </g>
        <g v-for="(leg, i) in legs" :key="'d' + i">
          <text v-if="leg.distance != null && leg.path && leg.path.length" :x="-mid(leg.path)[0]" :y="mid(leg.path)[1] - stroke * 1.8" class="leg-label" :style="{ fontSize: fontSize + 'px' }" text-anchor="middle">{{ distText(leg.distance) }}</text>
        </g>
      </g>
    </svg>
    <div v-else class="route-map-empty"><slot>Route preview unavailable</slot></div>
    <div v-if="hasRoute && total != null" class="route-total"><span>{{ legs.length > 1 ? legs.length + ' legs' : 'Drive' }}</span><strong>{{ distText(total) }}</strong></div>
  </div>
</template>

<script setup>
// Minimap of a route: terrain + road graph from the shared minimap store, plus the legs and stops
// handed over by the Job Broker Lua (world coordinates; the map flips x like the phone minimap).
import { computed, onMounted, onUnmounted, ref, watch, nextTick } from 'vue'
import { useMinimapStore } from '../stores/minimapStore'
import { useBridge } from '@/bridge'

const props = defineProps({
  legs: { type: Array, default: () => [] },       // [{ kind: 'pickup'|'delivery'|'approach', path: [[x,y],...], distance }]
  points: { type: Object, default: () => ({}) },  // { player: [x,y], pickup: [x,y], delivery: [x,y], stops: [[x,y,kind]] }
  labels: { type: Boolean, default: true },
})
const store = useMinimapStore()
const { units } = useBridge()
const host = ref(null), mapHost = ref(null)
const aspect = ref(16 / 9)
const playerRot = computed(() => store.playerRotation || 0)

const hasRoute = computed(() => props.legs.some(l => l.path && l.path.length > 1))
const total = computed(() => props.legs.reduce((a, l) => a + (Number(l.distance) || 0), 0) || null)
const stopMarkers = computed(() => {
  const out = []
  if (props.points.pickup) out.push({ x: props.points.pickup[0], y: props.points.pickup[1], kind: 'pickup', label: props.labels ? 'Pickup' : '' })
  if (props.points.delivery) out.push({ x: props.points.delivery[0], y: props.points.delivery[1], kind: 'delivery', label: props.labels ? 'Delivery' : '' })
  for (const [i, s] of (props.points.stops || []).entries()) out.push({ x: s[0], y: s[1], kind: s[2] || 'delivery', label: props.labels ? String(i + 1) : '' })
  return out
})
const bounds = computed(() => {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
  const take = (x, y) => { x0 = Math.min(x0, -x); x1 = Math.max(x1, -x); y0 = Math.min(y0, y); y1 = Math.max(y1, y) }
  for (const l of props.legs) for (const p of l.path || []) take(p[0], p[1])
  for (const m of stopMarkers.value) take(m.x, m.y)
  if (props.points.player) take(props.points.player[0], props.points.player[1])
  if (!isFinite(x0)) return null
  let w = Math.max(x1 - x0, 250), h = Math.max(y1 - y0, 250)
  const pad = Math.max(w, h) * 0.16
  w += pad * 2; h += pad * 2
  // grow the short side so the box matches the container and nothing gets cropped
  const a = aspect.value || 16 / 9
  if (w / h < a) w = h * a; else h = w / a
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
  return { x: cx - w / 2, y: cy - h / 2, w, h }
})
const viewBox = computed(() => bounds.value ? `${bounds.value.x} ${bounds.value.y} ${bounds.value.w} ${bounds.value.h}` : '0 0 100 100')
const stroke = computed(() => bounds.value ? Math.max(bounds.value.w, bounds.value.h) / 150 : 2)
const fontSize = computed(() => stroke.value * 3.3)

const pts = path => (path || []).map(p => `${-p[0]},${p[1]}`).join(' ')
const mid = path => { const i = Math.floor((path.length - 1) / 2); return path[i] }
function distText(raw) { if (raw == null) return '—'; // the game formatter auto-scales tiny values to mm/cm; keep short hops at whole metres
  const v = Math.max(Number(raw) || 0, 1); const p = v < 1000 ? 0 : 1; return units?.buildString ? units.buildString('length', v, p) : v < 1000 ? Math.round(v) + ' m' : (v / 1000).toFixed(1) + ' km' }

let mapView = null
function syncMap() {
  if (!mapHost.value) { mapView?.dispose(); mapView = null; return }
  if (!mapView) mapView = store.mountMap(mapHost.value, {
    fit: 'slice', follow: false, showVehicles: false, roadOpacity: 0.85, terrainOpacity: 0.9,
  })
  mapView.setViewBox(viewBox.value)
}
watch([viewBox, hasRoute], () => nextTick(syncMap), { immediate: true })
let ro = null
onMounted(() => {
  store.acquire(); nextTick(syncMap)
  const measure = () => { const el = host.value; if (el && el.clientWidth && el.clientHeight) aspect.value = el.clientWidth / el.clientHeight }
  measure(); ro = new ResizeObserver(measure); if (host.value) ro.observe(host.value)
})
onUnmounted(() => { mapView?.dispose(); store.release(); if (ro) ro.disconnect() })
</script>

<style scoped>
.route-map { position: relative; width: 100%; aspect-ratio: 16 / 9; border-radius: 0.5em; overflow: hidden; background: #202124; }
.route-base { position: absolute; inset: 0; overflow: hidden; }
.route-svg { position: relative; display: block; width: 100%; height: 100%; }
.roads :deep(line) { stroke-linecap: round; opacity: 0.85; }
.terrain image { opacity: 0.9; }
.leg-halo { fill: none; stroke: rgba(0, 0, 0, 0.55); stroke-linecap: round; stroke-linejoin: round; }
.leg { fill: none; stroke: var(--bng-orange-b400, #ff6600); stroke-linecap: round; stroke-linejoin: round; }
.leg.pickup, .leg.approach { stroke: rgba(255, 255, 255, 0.85); }
.stop-halo { fill: rgba(0, 0, 0, 0.5); }
.stop { fill: var(--bng-orange-b400, #ff6600); stroke: #fff; stroke-width: 0.6; }
.stop.delivery { fill: #fff; stroke: #1a1a1a; }
.player { fill: var(--bng-orange-b400, #ff6600); stroke: #fff; stroke-width: 0.5; }
.stop-label, .leg-label { fill: #fff; font-family: "Overpass", sans-serif; font-weight: 700; paint-order: stroke; stroke: rgba(0, 0, 0, 0.85); stroke-width: 0.35em; stroke-linejoin: round; }
.route-map-empty { position: absolute; inset: 0; display: grid; place-items: center; color: rgba(255, 255, 255, 0.45); font-size: 0.85em; }
.route-total { position: absolute; right: 0.5em; bottom: 0.45em; display: flex; align-items: baseline; gap: 0.4em; padding: 0.35em 0.6em 0.2em; border-radius: 0.35em; background: rgba(0, 0, 0, 0.6); font-size: 0.85em; }
.route-total span { color: rgba(255, 255, 255, 0.65); }
.route-total strong { color: #fff; }
</style>
