<template>
  <PhoneWrapper app-name="Events" status-font-color="#1f2328" status-blend-mode="normal">
    <div class="fre-app">
      <div v-if="!careerActive && loaded" class="empty-state">
        <p>Start a career to view events.</p>
      </div>

      <div v-if="!loaded" class="empty-state">
        <p>Loading events...</p>
      </div>

      <template v-if="careerActive && loaded">
        <!-- Toolbar -->
        <div class="toolbar">
          <div class="view-toggle">
            <button :class="{ active: viewMode === 'list' }" @click="viewMode = 'list'">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
              List
            </button>
            <button :class="{ active: viewMode === 'map' }" @click="viewMode = 'map'">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="1 6 1 22 8 18 16 22 23 18 23 2 16 6 8 2 1 6"/><line x1="8" y1="2" x2="8" y2="18"/><line x1="16" y1="6" x2="16" y2="22"/></svg>
              Map
            </button>
          </div>
          <div v-if="viewMode === 'list'" class="toolbar-row-2">
            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: filterOpen }" @click="filterOpen = !filterOpen; sortOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>
                Filter
                <svg class="dropdown-chevron" :class="{ open: filterOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
              </button>
              <div v-if="filterOpen" class="dropdown-panel filter-panel">
                <div class="filter-types">
                  <button
                    v-for="t in allTypes"
                    :key="t"
                    class="type-badge filter-type-btn"
                    :class="{ active: activeTypeFilters.has(t) }"
                    :style="{ '--badge-color': typeColors[t] || '#888' }"
                    @click="toggleTypeFilter(t)"
                  >{{ typeLabels[t] || t }}</button>
                </div>
                <label class="filter-opt">
                  <span class="custom-checkbox" :class="{ checked: filterHasTime }"><span class="custom-checkbox-dot"></span></span>
                  <input type="checkbox" v-model="filterHasTime" class="sr-only" />
                  Has best time
                </label>
                <button class="filter-clear" @click="clearFilters">Clear</button>
              </div>
            </div>
            <div class="dropdown-wrap">
              <button class="dropdown-btn" :class="{ active: sortOpen }" @click="sortOpen = !sortOpen; filterOpen = false">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="14" y2="12"/><line x1="4" y1="18" x2="9" y2="18"/></svg>
                Sort
                <svg class="dropdown-chevron" :class="{ open: sortOpen }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="6 9 12 15 18 9"/></svg>
              </button>
              <div v-if="sortOpen" class="dropdown-panel sort-panel">
                <div class="sort-grid">
                  <span class="sort-label">By</span>
                  <div class="sort-options">
                    <button v-for="f in sortFields" :key="f.key" class="sort-opt" :class="{ active: sortBy === f.key }" @click="sortBy = f.key">{{ f.label }}</button>
                  </div>
                  <span class="sort-label">Order</span>
                  <div class="sort-options">
                    <button class="sort-opt" :class="{ active: sortAsc }" @click="sortAsc = true">Asc</button>
                    <button class="sort-opt" :class="{ active: !sortAsc }" @click="sortAsc = false">Desc</button>
                  </div>
                </div>
              </div>
            </div>
            <span class="toolbar-count">{{ sortedEvents.length }} shown</span>
          </div>
        </div>

        <!-- LIST VIEW -->
        <div class="list-view" v-if="viewMode === 'list'">
          <div v-if="sortedEvents.length === 0" class="empty-state small">No events match filters.</div>
          <div
            v-for="ev in sortedEvents"
            :key="ev.raceName"
            class="card"
            @click="toggleExpand(ev.raceName)"
          >
            <div class="card-img">
              <img v-if="!imgFailed(ev.raceName)" :src="ev.thumbnail" alt="" @error="onImgError(ev.raceName)" />
              <div v-else class="card-img-ph">
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.35)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
                <span>No preview</span>
              </div>
              <div class="card-img-fade"></div>
              <div class="card-badges">
                <span
                  v-for="t in ensureTypesArray(ev)"
                  :key="t"
                  class="badge"
                  :style="{ background: typeColors[t] || '#888' }"
                >{{ typeLabels[t] || t }}</span>
              </div>
              <div class="card-target" v-if="ev.bestTime">Target: {{ formatTime(ev.bestTime) }}</div>
            </div>
            <div class="card-body">
              <div class="card-info">
                <span class="card-name">{{ ev.label }}</span>
                <div class="card-meta">
                  <span class="meta-item" v-if="ev.currentVehicleBestTime">
                    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
                    {{ formatTime(ev.currentVehicleBestTime) }}
                  </span>
                  <span class="meta-item no-time" v-else>No time set</span>
                  <span class="meta-item" v-if="ev.distance >= 0">
                    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                    {{ formatDistance(ev.distance) }}
                  </span>
                </div>
              </div>
              <svg class="chevron" :class="{ open: expandedId === ev.raceName }" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.45)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
            </div>
            <div class="card-expand" v-if="expandedId === ev.raceName" @click.stop>
              <div class="card-actions">
                <button class="act-btn route" @click.stop="setRoute(ev.raceName)">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                  Set Route
                </button>
              </div>
              <div class="detail-section">
                <div class="detail-heading">Event Goals</div>
                <div class="detail-grid">
                  <div class="detail-row">
                    <span class="detail-label">Target Time</span>
                    <span class="detail-value">{{ formatTime(ev.bestTime) }}</span>
                  </div>
                  <div class="detail-row">
                    <span class="detail-label">Reward</span>
                    <span class="detail-value">${{ formatPrice(ev.reward) }}</span>
                  </div>
                  <div class="detail-row" v-if="ev.hotlap">
                    <span class="detail-label">Hotlap</span>
                    <span class="detail-value">{{ formatTime(ev.hotlap) }}</span>
                  </div>
                  <div class="detail-row" v-if="ev.hasDamageFactor">
                    <span class="detail-label">Damage</span>
                    <span class="detail-value">{{ Math.round(ev.damageFactor * 100) }}%</span>
                  </div>
                  <div class="detail-row" v-if="ev.hasTopSpeed && ev.topSpeedGoal">
                    <span class="detail-label">Speed</span>
                    <span class="detail-value">{{ ev.topSpeedGoal.toFixed(1) }} mph</span>
                  </div>
                  <div class="detail-row" v-if="ev.hasDrift && ev.driftGoal">
                    <span class="detail-label">Drift</span>
                    <span class="detail-value">{{ ev.driftGoal.toLocaleString() }} pts</span>
                  </div>
                </div>
              </div>
              <div class="detail-section" v-if="ev.hasAltRoute">
                <div class="detail-heading">Alternative Route</div>
                <div class="detail-row">
                  <span class="detail-label">{{ ev.altRouteLabel }}</span>
                  <span class="detail-value">{{ formatTime(ev.altRouteBestTime) }} · ${{ formatPrice(ev.altRouteReward) }}</span>
                </div>
              </div>
              <div class="detail-section">
                <div class="detail-heading">Your Progress</div>
                <div class="detail-row">
                  <span class="detail-label">{{ ev.currentVehicleName || 'No Vehicle' }}</span>
                  <span class="detail-value">{{ ev.currentVehicleBestTime ? formatTime(ev.currentVehicleBestTime) : 'No time' }}</span>
                </div>
              </div>
              <div class="detail-section" v-if="ev.vehicleRecords && ev.vehicleRecords.length > 0">
                <div class="detail-heading">Records</div>
                <div class="records-list">
                  <div class="record-row" v-for="rec in ev.vehicleRecords" :key="rec.inventoryId">
                    <span class="record-name">{{ rec.vehicleName }}</span>
                    <span class="record-time">
                      <template v-if="rec.time">{{ formatTime(rec.time) }}</template>
                      <template v-if="rec.driftScore"> · {{ rec.driftScore.toLocaleString() }} pts</template>
                      <template v-if="rec.topSpeed"> · {{ rec.topSpeed.toFixed(1) }} mph</template>
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- MAP VIEW -->
        <div class="map-view" v-if="viewMode === 'map'" ref="mapContainer">
          <div
            class="map-layers"
            @pointerdown="onMapPointerDown"
            @pointermove="onMapPointerMove"
            @pointerup="onMapPointerUp"
            @pointercancel="onMapPointerUp"
            @pointerleave="onMapPointerUp"
            @wheel.prevent="onMapWheel"
          >
            <svg class="map-layer terrain-layer"></svg>
            <svg class="map-layer roads-layer"></svg>
            <svg class="map-layer vehicle-layer"></svg>
            <svg class="map-layer marker-layer" :viewBox="markerViewBox">
              <g v-for="item in clusteredMarkers" :key="'m-' + item.cluster[0].raceName"
                :transform="'translate(' + (-item.posX) + ',' + item.posY + ') scale(' + zoomFactor + ')'"
                class="event-marker"
                :class="{ selected: selectedEvent && item.cluster.some(e => e.raceName === selectedEvent.raceName), cluster: item.count > 1 }"
                @click.stop="selectMarker(item.cluster[0])"
              >
                <circle r="18" class="marker-bg" />
                <circle r="12" class="marker-dot" :style="{ fill: item.count === 1 ? getEventColor(item.cluster[0]) : '#888' }" />
                <template v-if="item.count > 1">
                  <text y="0" text-anchor="middle" dominant-baseline="middle" class="marker-label marker-count">{{ item.count }}</text>
                </template>
                <template v-else>
                  <svg x="-7.5" y="-7.5" width="15" height="15" viewBox="0 0 24 24" fill="white" stroke="none"><path d="M 5,4 l 4,0 0,2 2,0 0,-2 2,0 0.39,0.08 0.32,0.21 0.21,0.32 0.08,0.39 0,2 1,0 0,-2 2,0 0,2 1,0 0,-2 0.08,-0.39 0.21,-0.32 0.32,-0.21 0.39,-0.08 0,10 -0.08,0.39 -0.21,0.32 -0.32,0.21 -0.39,0.08 0,-2 -1,0 0,2 -2,0 0,-2 -1,0 0,2 -0.39,-0.08 -0.32,-0.21 -0.21,-0.32 -0.08,-0.39 -2,0 0,-2 -2,0 0,2 -2,0 0,6 -2,0 0,-16 Z M 7,6 l 0,2 2,0 0,2 -2,0 0,2 2,0 0,-2 2,0 0,2 2,0 0,-2 -2,0 0,-2 2,0 0,-2 -2,0 0,2 -2,0 0,-2 -2,0 Z M 15,9 l 2,0 0,-2 -2,0 0,2 Z M 17,11 l -2,0 0,2 2,0 0,-2 Z M 15,11 l 0,-2 -1,0 0,2 1,0 Z M 17,11 l 1,0 0,-2 -1,0 0,2 Z" fill-rule="evenodd"/></svg>
                  <text y="28" text-anchor="middle" class="marker-label">{{ item.cluster[0].label }}</text>
                </template>
              </g>
            </svg>
          </div>

          <!-- Bottom carousel -->
          <div class="map-carousel-wrap">
            <div
              class="map-carousel-viewport"
              ref="carouselViewportRef"
              @pointerdown.capture="onCarouselPointerDown"
              @click="onCarouselViewportClick"
            >
              <div
                class="map-carousel-track"
                :class="{ 'no-transition': isDraggingCarousel || isWrappingCarousel }"
                :style="{ '--carousel-duration': carouselTransitionDuration + 's', '--carousel-slide-width': carouselSlideWidth + 'px', transform: `translateX(${carouselOffset}px)` }"
              >
                <article
                  v-for="(ev, idx) in carouselEvents"
                  :key="'c-' + ev.raceName + '-' + idx"
                  class="map-slide"
                  :class="{ selected: selectedEvent && selectedEvent.raceName === ev.raceName }"
                  :style="{ flex: '0 0 ' + carouselSlideWidth + 'px', width: carouselSlideWidth + 'px' }"
                >
                  <div class="map-slide-img">
                    <img v-if="!imgFailed(ev.raceName)" :src="ev.thumbnail" alt="" draggable="false" @error="onImgError(ev.raceName)" />
                    <div v-else class="card-img-ph small">
                      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="rgba(31,35,40,0.35)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
                    </div>
                    <div class="map-slide-img-fade"></div>
                    <div class="map-slide-badges">
                      <span
                        v-for="t in ensureTypesArray(ev)"
                        :key="t"
                        class="badge"
                        :style="{ background: typeColors[t] || '#888' }"
                      >{{ typeLabels[t] || t }}</span>
                    </div>
                  </div>
                  <div class="map-slide-body">
                    <div class="map-slide-top">
                      <span class="map-slide-name">{{ ev.label }}</span>
                    </div>
                    <div class="map-slide-meta-row">
                      <div class="map-slide-meta">
                        <span v-if="ev.currentVehicleBestTime">
                          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
                          {{ formatTime(ev.currentVehicleBestTime) }}
                        </span>
                        <span v-else class="no-time">No time</span>
                        <span v-if="ev.distance >= 0">
                          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                          {{ formatDistance(ev.distance) }}
                        </span>
                      </div>
                      <button class="act-btn route" @click.stop="setRoute(ev.raceName)">
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                        Route
                      </button>
                    </div>
                  </div>
                </article>
              </div>
            </div>
          </div>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { useMinimapStore } from '../stores/minimapStore'
import PhoneWrapper from './PhoneWrapper.vue'

const events = useEvents()
const minimapStore = useMinimapStore()

const eventsData = ref({})
const careerActive = ref(true)
const loaded = ref(false)
const levelId = ref('')
const currentVehicleName = ref('')

const viewMode = ref('list')
const expandedId = ref(null)
const selectedEvent = ref(null)
const sortOpen = ref(false)
const filterOpen = ref(false)
const sortBy = ref('name')
const sortAsc = ref(true)
const filterHasTime = ref(false)
const activeTypeFilters = reactive(new Set())
const failedImages = reactive(new Set())

const mapContainer = ref(null)
const markerViewBox = ref('0 0 1000 1000')
const freBaseViewBox = ref('0 0 1000 1000')
const panOffset = reactive({ x: 0, y: 0 })
const zoomFactor = ref(1)
const panState = reactive({ active: false, moved: false, lastX: 0, lastY: 0, pointerId: null })
const suppressMarkerClickUntil = ref(0)
let resizeObserver = null
let carouselResizeObserver = null
let mapFocusAnimationFrame = null

const carouselViewportRef = ref(null)
const carouselWidth = ref(340)
const carouselSlideIndex = ref(0)
const carouselDragDelta = ref(0)
const carouselTransitionDuration = ref(0.35)
const isDraggingCarousel = ref(false)
const isWrappingCarousel = ref(false)
const carouselPointerStart = reactive({ x: 0 })
let carouselPointerId = null
const suppressCarouselClickUntil = ref(0)
const mapContainerSize = ref({ width: 400, height: 400 })
const CLUSTER_RADIUS_PX = 50

const sortFields = [
  { key: 'name', label: 'Name' },
  { key: 'distance', label: 'Distance' },
  { key: 'bestTime', label: 'Best Time' },
  { key: 'reward', label: 'Reward' },
]

const typeColors = {
  street: '#3b82f6',
  offroad: '#84cc16',
  drift: '#a855f7',
  oval: '#f59e0b',
  drag: '#ef4444',
  topSpeed: '#06b6d4',
  rally: '#22c55e',
  koh: '#d97706',
}

const typeLabels = {
  street: 'Street',
  offroad: 'Offroad',
  drift: 'Drift',
  oval: 'Oval',
  drag: 'Drag',
  topSpeed: 'Top Speed',
  rally: 'Rally',
  koh: 'KOH',
}

const eventsList = computed(() => {
  const val = eventsData.value
  if (Array.isArray(val)) return val
  if (val && typeof val === 'object') return Object.values(val)
  return []
})

function ensureTypesArray(ev) {
  const t = ev?.types
  if (Array.isArray(t)) return t
  return t != null ? [t] : []
}

const allTypes = computed(() => {
  const types = new Set()
  eventsList.value.forEach(ev => {
    ensureTypesArray(ev).forEach(t => types.add(t))
  })
  return [...types].sort()
})

const filteredEvents = computed(() => {
  let list = eventsList.value
  if (activeTypeFilters.size > 0) {
    list = list.filter(ev => ensureTypesArray(ev).some(t => activeTypeFilters.has(t)))
  }
  if (filterHasTime.value) {
    list = list.filter(ev => ev.currentVehicleBestTime)
  }
  return list
})

const sortedEvents = computed(() => {
  const arr = [...filteredEvents.value]
  const key = sortBy.value
  const asc = sortAsc.value
  arr.sort((a, b) => {
    let va, vb
    switch (key) {
      case 'name':
        va = (a.label || '').toLowerCase()
        vb = (b.label || '').toLowerCase()
        return asc ? va.localeCompare(vb) : vb.localeCompare(va)
      case 'distance':
        va = a.distance < 0 ? 1e9 : a.distance
        vb = b.distance < 0 ? 1e9 : b.distance
        break
      case 'bestTime':
        va = a.currentVehicleBestTime || 1e9
        vb = b.currentVehicleBestTime || 1e9
        break
      case 'reward':
        va = a.reward || 0
        vb = b.reward || 0
        break
      default:
        return 0
    }
    if (va < vb) return asc ? -1 : 1
    if (va > vb) return asc ? 1 : -1
    return 0
  })
  return arr
})

const eventsWithPos = computed(() => {
  return filteredEvents.value.filter(ev => ev.position && ev.position.x !== undefined)
})

function worldToPixelDist(dxWorld, dyWorld, viewBox, containerW, containerH) {
  const scaleX = containerW / viewBox.w
  const scaleY = containerH / viewBox.h
  return Math.hypot(dxWorld * scaleX, dyWorld * scaleY)
}

function clusterEvents(events, viewBoxStr, containerSize) {
  const result = []
  const assigned = new Set()
  const box = parseViewBox(viewBoxStr)
  const cw = Math.max(1, containerSize.width)
  const ch = Math.max(1, containerSize.height)

  for (const ev of events) {
    if (assigned.has(ev.raceName)) continue
    const cluster = [ev]
    assigned.add(ev.raceName)
    let changed = true
    while (changed) {
      changed = false
      for (const other of events) {
        if (assigned.has(other.raceName)) continue
        for (const c of cluster) {
          const distPx = worldToPixelDist(
            other.position.x - c.position.x,
            other.position.y - c.position.y,
            box, cw, ch
          )
          if (distPx <= CLUSTER_RADIUS_PX) {
            cluster.push(other)
            assigned.add(other.raceName)
            changed = true
            break
          }
        }
      }
    }
    const posX = cluster.reduce((s, x) => s + x.position.x, 0) / cluster.length
    const posY = cluster.reduce((s, x) => s + x.position.y, 0) / cluster.length
    result.push({ cluster, posX, posY, count: cluster.length })
  }
  return result
}

const clusteredMarkers = computed(() =>
  clusterEvents(eventsWithPos.value, markerViewBox.value, mapContainerSize.value)
)

const carouselCycleLen = computed(() => filteredEvents.value.length)
const carouselEvents = computed(() => {
  const list = filteredEvents.value
  if (list.length < 2) return list
  return [...list, ...list, ...list]
})
const carouselSlideWidth = computed(() => Math.max(292, carouselWidth.value - 28))
const carouselSlideStep = computed(() => carouselSlideWidth.value + 10)
const carouselOffset = computed(() => {
  return -carouselSlideIndex.value * carouselSlideStep.value + carouselDragDelta.value
})

function formatTime(seconds) {
  if (!seconds && seconds !== 0) return '--:--:--'
  const sign = seconds < 0 ? '-' : ''
  seconds = Math.abs(seconds)
  const mins = Math.floor(seconds / 60)
  const secs = seconds % 60
  const whole = Math.floor(secs)
  const hundredths = Math.floor((secs - whole) * 100)
  return `${sign}${String(mins).padStart(2, '0')}:${String(whole).padStart(2, '0')}:${String(hundredths).padStart(2, '0')}`
}

function formatPrice(val) {
  if (val == null) return '0'
  return Number(val).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })
}

function formatDistance(m) {
  if (m < 0) return '--'
  if (m >= 1000) return (m / 1000).toFixed(1) + ' km'
  return Math.round(m) + ' m'
}

function getEventColor(ev) {
  const types = ensureTypesArray(ev)
  if (types.length > 0) return typeColors[types[0]] || '#888'
  return '#888'
}

function imgFailed(id) { return failedImages.has(id) }
function onImgError(id) { failedImages.add(id) }

function toggleExpand(id) {
  expandedId.value = expandedId.value === id ? null : id
}

function toggleTypeFilter(type) {
  if (activeTypeFilters.has(type)) activeTypeFilters.delete(type)
  else activeTypeFilters.add(type)
}

function clearFilters() {
  activeTypeFilters.clear()
  filterHasTime.value = false
}

function getNearestEvent(list) {
  if (!Array.isArray(list) || !list.length) return null
  let nearest = null
  let nearestDist = Infinity
  for (const ev of list) {
    const d = Number(ev?.distance)
    const nd = Number.isFinite(d) && d >= 0 ? d : Infinity
    if (nd < nearestDist) {
      nearestDist = nd
      nearest = ev
    }
  }
  return nearest || list[0]
}

function selectMarker(ev) {
  if (Date.now() < suppressMarkerClickUntil.value) return
  focusEvent(ev, { centerMap: true, animateCenterMap: true })
}

function focusEvent(ev, options = {}) {
  selectedEvent.value = ev
  scrollToEventCard(ev.raceName)
  if (options.centerMap) centerMapOnEvent(ev, options.animateCenterMap)
}

async function setRoute(raceName) {
  if (lua.ui_phone_freeroamEvents?.navigateToEvent) {
    await lua.ui_phone_freeroamEvents.navigateToEvent(raceName)
  }
}

// Map viewBox management
function parseViewBox(viewBoxString) {
  const raw = (viewBoxString || '0 0 1000 1000').split(' ').map(Number)
  if (raw.length !== 4 || raw.some(Number.isNaN)) return { x: 0, y: 0, w: 1000, h: 1000 }
  return { x: raw[0], y: raw[1], w: raw[2], h: raw[3] }
}

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
  if (minimapStore.viewControlledBy === 'freeroamEvents') return parseViewBox(freBaseViewBox.value)
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
  if (minimapStore.svgLayers?.terrain) minimapStore.svgLayers.terrain.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.roads) minimapStore.svgLayers.roads.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.vehicles) minimapStore.svgLayers.vehicles.setAttribute('viewBox', effective)
  if (minimapStore.svgLayers?.aux) minimapStore.svgLayers.aux.setAttribute('viewBox', effective)
}

function stopMapFocusAnimation() {
  if (mapFocusAnimationFrame != null) {
    cancelAnimationFrame(mapFocusAnimationFrame)
    mapFocusAnimationFrame = null
  }
}

function animateMapPanTo(targetX, targetY, durationMs = 320) {
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

function centerMapOnEvent(ev, animate = false) {
  if (!ev?.position) return
  const posX = Number(ev.position.x)
  const posY = Number(ev.position.y)
  if (!Number.isFinite(posX) || !Number.isFinite(posY)) return
  const base = getMapBaseViewBox()
  const targetPanX = -posX - (base.x + base.w / 2)
  const targetPanY = posY - (base.y + base.h / 2)
  if (animate) {
    animateMapPanTo(targetPanX, targetPanY)
    return
  }
  stopMapFocusAnimation()
  panOffset.x = targetPanX
  panOffset.y = targetPanY
  applyEffectiveViewBox()
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
  if (panState.moved) suppressMarkerClickUntil.value = Date.now() + 120
  panState.active = false
  panState.moved = false
  panState.pointerId = null
}

// Carousel logic
function scrollToEventCard(raceName) {
  if (!raceName) return
  const list = filteredEvents.value
  const index = list.findIndex(e => e.raceName === raceName)
  if (index < 0) return
  const targetIdx = list.length >= 2 ? carouselCycleLen.value + index : index
  const delta = Math.abs(targetIdx - carouselSlideIndex.value)
  carouselTransitionDuration.value = delta > 1 ? Math.min(0.7, 0.3 + delta * 0.025) : 0.35
  carouselSlideIndex.value = targetIdx
}

function onCarouselPointerDown(event) {
  const viewport = event.currentTarget
  if (!viewport) return
  carouselPointerId = event.pointerId
  carouselPointerStart.x = event.clientX
  carouselDragDelta.value = 0
  isDraggingCarousel.value = false
  document.addEventListener('pointermove', onCarouselDocMove)
  document.addEventListener('pointerup', onCarouselDocUp)
  document.addEventListener('pointercancel', onCarouselDocUp)
}

function onCarouselDocMove(event) {
  if (event.pointerId !== carouselPointerId) return
  const dx = event.clientX - carouselPointerStart.x
  if (!isDraggingCarousel.value && Math.abs(dx) > 8) {
    isDraggingCarousel.value = true
    const viewport = carouselViewportRef.value
    if (viewport?.setPointerCapture) {
      try { viewport.setPointerCapture(event.pointerId) } catch (_) {}
    }
  }
  if (isDraggingCarousel.value) {
    event.preventDefault()
    carouselDragDelta.value = Math.max(-carouselSlideStep.value, Math.min(carouselSlideStep.value, dx))
  }
}

function onCarouselDocUp(event) {
  if (event.pointerId !== carouselPointerId) return
  const viewport = carouselViewportRef.value
  if (viewport?.releasePointerCapture) {
    try { viewport.releasePointerCapture(event.pointerId) } catch (_) {}
  }
  document.removeEventListener('pointermove', onCarouselDocMove)
  document.removeEventListener('pointerup', onCarouselDocUp)
  document.removeEventListener('pointercancel', onCarouselDocUp)
  if (isDraggingCarousel.value) {
    const threshold = carouselSlideStep.value * 0.25
    const cycleLen = carouselCycleLen.value
    const evs = carouselEvents.value
    const WRAP_ANIM_MS = 350
    if (carouselDragDelta.value < -threshold) {
      const next = carouselSlideIndex.value + 1
      const willWrap = cycleLen >= 2 && next >= 2 * cycleLen
      if (willWrap) {
        isDraggingCarousel.value = false
        carouselDragDelta.value = 0
        carouselTransitionDuration.value = 0.35
        carouselSlideIndex.value = next
        if (evs[next]) selectedEvent.value = evs[next]
        setTimeout(() => {
          isWrappingCarousel.value = true
          carouselSlideIndex.value = cycleLen
          nextTick(() => requestAnimationFrame(() => { isWrappingCarousel.value = false }))
        }, WRAP_ANIM_MS)
      } else {
        carouselSlideIndex.value = cycleLen >= 2 ? next : Math.min(next, evs.length - 1)
        if (evs[carouselSlideIndex.value]) selectedEvent.value = evs[carouselSlideIndex.value]
      }
    } else if (carouselDragDelta.value > threshold) {
      const prev = carouselSlideIndex.value - 1
      const willWrap = cycleLen >= 2 && prev < cycleLen
      if (willWrap) {
        isDraggingCarousel.value = false
        carouselDragDelta.value = 0
        carouselTransitionDuration.value = 0.35
        carouselSlideIndex.value = prev
        if (evs[prev]) selectedEvent.value = evs[prev]
        setTimeout(() => {
          isWrappingCarousel.value = true
          carouselSlideIndex.value = 2 * cycleLen - 1
          nextTick(() => requestAnimationFrame(() => { isWrappingCarousel.value = false }))
        }, WRAP_ANIM_MS)
      } else {
        carouselSlideIndex.value = cycleLen >= 2 ? prev : Math.max(0, prev)
        if (evs[carouselSlideIndex.value]) selectedEvent.value = evs[carouselSlideIndex.value]
      }
    }
    suppressCarouselClickUntil.value = Date.now() + 150
  }
  isDraggingCarousel.value = false
  carouselDragDelta.value = 0
}

function onCarouselViewportClick(event) {
  if (Date.now() < suppressCarouselClickUntil.value) return
  const viewport = carouselViewportRef.value
  if (!viewport) return
  const track = viewport.querySelector('.map-carousel-track')
  const rect = viewport.getBoundingClientRect()
  const trackPadding = track ? parseFloat(getComputedStyle(track).paddingLeft) || 0 : 0
  const x = event.clientX - rect.left - trackPadding - carouselOffset.value
  const step = carouselSlideStep.value
  if (step <= 0) return
  const idx = Math.floor(x / step)
  const ev = carouselEvents.value[Math.max(0, Math.min(idx, carouselEvents.value.length - 1))]
  if (ev) focusEvent(ev, { centerMap: true, animateCenterMap: true })
}

function initCarouselScroll() {
  const list = filteredEvents.value
  if (list.length < 2) {
    carouselSlideIndex.value = 0
    return
  }
  carouselSlideIndex.value = carouselCycleLen.value
  if (selectedEvent.value) {
    const idx = list.findIndex(e => e.raceName === selectedEvent.value.raceName)
    if (idx >= 0) carouselSlideIndex.value = carouselCycleLen.value + idx
  }
}

function updateContainerSize() {
  if (!mapContainer.value) return
  const r = mapContainer.value.getBoundingClientRect()
  if (r.width > 0 && r.height > 0) mapContainerSize.value = { width: r.width, height: r.height }
}

function updateCarouselWidth() {
  const el = carouselViewportRef.value
  if (el) {
    const w = el.getBoundingClientRect().width
    if (w > 0) carouselWidth.value = w
  }
}

function initMap() {
  if (!mapContainer.value) return
  const terrainLayer = mapContainer.value.querySelector('.terrain-layer')
  const roadsLayer = mapContainer.value.querySelector('.roads-layer')
  const vehicleLayer = mapContainer.value.querySelector('.vehicle-layer')
  if (vehicleLayer) {
    if (terrainLayer) {
      if (!minimapStore.showTerrainImage) {
        const images = Array.from(minimapStore.svgLayers.terrain.children).filter(child => child.tagName === 'image')
        images.forEach(img => minimapStore.svgLayers.terrain.removeChild(img))
      }
      terrainLayer.appendChild(minimapStore.svgLayers.terrain)
    }
    if (roadsLayer) roadsLayer.appendChild(minimapStore.svgLayers.roads)
    vehicleLayer.appendChild(minimapStore.svgLayers.vehicles)
    updateContainerSize()
    applyEffectiveViewBox()
    updateCarouselWidth()
    if (typeof ResizeObserver !== 'undefined') {
      resizeObserver?.disconnect()
      resizeObserver = new ResizeObserver(() => updateContainerSize())
      resizeObserver.observe(mapContainer.value)
      carouselResizeObserver?.disconnect()
      carouselResizeObserver = new ResizeObserver(() => updateCarouselWidth())
      nextTick(() => {
        if (carouselViewportRef.value) carouselResizeObserver.observe(carouselViewportRef.value)
      })
    }
  }
}

async function mountMapIfVisible() {
  if (viewMode.value !== 'map' || !careerActive.value || !loaded.value) return
  await nextTick()
  initMap()
}

watch([viewMode, careerActive, loaded], async ([newViewMode], [oldViewMode]) => {
  let shouldCenterNearestOnOpen = false
  if (viewMode.value !== 'map') {
    selectedEvent.value = null
    minimapStore.viewControlledBy = null
    minimapStore.showTerrainImage = true
  } else {
    filterOpen.value = false
    sortOpen.value = false
    if (oldViewMode !== 'map') {
      freBaseViewBox.value = buildWalkingZoomBaseViewBox()
    }
    minimapStore.viewControlledBy = 'freeroamEvents'
    minimapStore.showTerrainImage = false
    if (oldViewMode !== 'map') {
      const nearest = getNearestEvent(filteredEvents.value)
      if (nearest) {
        selectedEvent.value = nearest
        shouldCenterNearestOnOpen = true
      }
    }
  }
  await mountMapIfVisible()
  nextTick(() => {
    initCarouselScroll()
    if (newViewMode === 'map' && shouldCenterNearestOnOpen && selectedEvent.value) {
      focusEvent(selectedEvent.value, { centerMap: true, animateCenterMap: true })
    }
  })
}, { immediate: true })

watch(() => minimapStore.viewBox, () => {
  if (minimapStore.viewControlledBy === 'freeroamEvents') return
  applyEffectiveViewBox()
})

watch(filteredEvents, (list) => {
  if (viewMode.value !== 'map') return
  if (!list.length) {
    selectedEvent.value = null
    return
  }
  const shouldAutoSelect = !selectedEvent.value || !list.find(e => e.raceName === selectedEvent.value.raceName)
  if (shouldAutoSelect) selectedEvent.value = getNearestEvent(list)
  nextTick(() => {
    initCarouselScroll()
    if (!selectedEvent.value) return
    if (shouldAutoSelect) focusEvent(selectedEvent.value, { centerMap: true, animateCenterMap: true })
    else scrollToEventCard(selectedEvent.value.raceName)
  })
})

onMounted(async () => {
  minimapStore.init()

  events.on('phoneFreeroamEventsData', (data) => {
    failedImages.clear()
    if (!data.careerActive) {
      careerActive.value = false
      loaded.value = true
      return
    }
    careerActive.value = true
    eventsData.value = data.events || {}
    levelId.value = data.levelId || ''
    currentVehicleName.value = data.currentVehicleName || ''
    loaded.value = true
    mountMapIfVisible()
  })

  try {
    await lua.extensions.load('ui_phone_layout')
    careerActive.value = await lua.ui_phone_layout.getCareerActive()
  } catch {
    careerActive.value = false
  }

  if (careerActive.value) {
    try {
      await lua.extensions.load('ui_phone_freeroamEvents')
      if (lua.ui_phone_freeroamEvents?.getEventsData) {
        lua.ui_phone_freeroamEvents.getEventsData()
      } else {
        loaded.value = true
      }
    } catch {
      loaded.value = true
    }
  } else {
    loaded.value = true
  }

  setTimeout(() => { if (!loaded.value) loaded.value = true }, 2000)
  await mountMapIfVisible()
})

onUnmounted(() => {
  stopMapFocusAnimation()
  minimapStore.viewControlledBy = null
  minimapStore.showTerrainImage = true
  resizeObserver?.disconnect()
  resizeObserver = null
  carouselResizeObserver?.disconnect()
  carouselResizeObserver = null
  minimapStore.cleanup()
})
</script>

<style scoped lang="scss">
.fre-app {
  height: 100%;
  position: relative;
  background: #f6f4ef;
  color: #1f2328;
  overflow: hidden;
  border-radius: 0 0 16px 16px;
}

.empty-state {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: rgba(31,35,40,0.55);
  font-size: 14px;
  &.small { position: relative; inset: auto; font-size: 13px; padding: 40px 20px; flex: 0; }
}

.toolbar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 1;
  padding: 44px 10px 8px;
  border-radius: 0 0 24px 24px;
  background: #f6f4ef;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.view-toggle {
  display: flex;
  background: #e7e2d7;
  border-radius: 8px;
  padding: 2px;
  gap: 2px;
  button {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 4px;
    padding: 5px 10px;
    border: none;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    font-family: inherit;
    color: rgba(31,35,40,0.55);
    background: transparent;
    cursor: pointer;
    transition: all 0.15s ease;
    &.active {
      background: #ffffff;
      color: #1f2328;
    }
  }
}

.toolbar-row-2 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.toolbar-count {
  margin-left: auto;
  font-size: 10px;
  color: rgba(31,35,40,0.55);
}

.dropdown-wrap { position: relative; }

.dropdown-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 5px 10px;
  border-radius: 8px;
  border: 1px solid rgba(31,35,40,0.16);
  background: #ffffff;
  color: rgba(31,35,40,0.8);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  transition: all 0.15s ease;
  &.active {
    background: #e63946;
    border-color: #e63946;
    color: white;
  }
}

.dropdown-chevron {
  transition: transform 0.15s ease;
  &.open { transform: rotate(180deg); }
}

.dropdown-panel {
  position: absolute;
  top: 100%;
  left: 0;
  margin-top: 4px;
  z-index: 100;
  min-width: 220px;
  max-height: 70vh;
  overflow-y: auto;
  border-radius: 10px;
  border: 1px solid rgba(31,35,40,0.14);
  box-shadow: 0 8px 24px rgba(31,35,40,0.12);
}

.filter-panel,
.sort-panel {
  padding: 14px;
  background: #ffffff;
  border-radius: 12px;
  border: 1px solid rgba(31,35,40,0.14);
  box-shadow: 0 8px 32px rgba(31,35,40,0.12);
}

.filter-panel {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.filter-types {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.type-badge {
  display: inline-flex;
  padding: 2px 7px;
  border-radius: 5px;
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.3px;
  background: var(--badge-color);
  color: #fff;
}

.filter-type-btn {
  cursor: pointer;
  opacity: 0.5;
  border: 1px solid transparent;
  &.active {
    opacity: 1;
    border-color: var(--badge-color);
  }
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0,0,0,0);
  border: 0;
}

.custom-checkbox {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 18px;
  height: 18px;
  border-radius: 50%;
  border: 1.5px solid rgba(31,35,40,0.3);
  flex-shrink: 0;
  cursor: pointer;
  transition: border-color 0.15s ease;
  .custom-checkbox-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #e63946;
    opacity: 0;
    transform: scale(0.5);
    transition: opacity 0.15s ease, transform 0.15s ease;
  }
  &.checked .custom-checkbox-dot {
    opacity: 1;
    transform: scale(1);
  }
  &.checked { border-color: rgba(230,57,70,0.5); }
}

.filter-opt {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: rgba(31,35,40,0.8);
  cursor: pointer;
}

.filter-clear {
  padding: 6px 12px;
  border-radius: 8px;
  border: 1px solid rgba(31,35,40,0.2);
  background: #f7f5f0;
  color: rgba(31,35,40,0.72);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  align-self: flex-start;
}

.sort-panel { min-width: 200px; }

.sort-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 6px 12px;
  align-items: center;
}

.sort-label {
  font-size: 11px;
  color: rgba(31,35,40,0.6);
}

.sort-options {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(60px, 1fr));
  gap: 4px;
}

.sort-opt {
  padding: 5px 10px;
  border-radius: 8px;
  border: 1px solid rgba(31,35,40,0.14);
  background: #ffffff;
  color: rgba(31,35,40,0.82);
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  cursor: pointer;
  transition: all 0.15s ease;
  &.active {
    background: #e63946;
    border-color: #e63946;
    color: white;
  }
}

/* LIST VIEW */
.list-view {
  position: absolute;
  inset: 0;
  overflow-y: auto;
  padding: 130px 10px 80px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  &::-webkit-scrollbar { width: 3px; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(31,35,40,0.22); border-radius: 2px; }
}

.card {
  flex-shrink: 0;
  min-height: 200px;
  background: #ffffff;
  border-radius: 16px;
  overflow: hidden;
  cursor: pointer;
  border: 1px solid rgba(31,35,40,0.12);
  transition: border-color 0.15s ease;
  &:active { background: #f2efe8; }
}

.card-img {
  position: relative;
  width: 100%;
  height: 160px;
  flex-shrink: 0;
  background: #ece7dc;
  overflow: hidden;
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }
}

.card-img-ph {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 6px;
  background: linear-gradient(135deg, #f3efe6, #e7dfd0);
  span {
    font-size: 10px;
    color: rgba(31,35,40,0.48);
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }
  &.small {
    height: 80px;
    span { display: none; }
  }
}

.card-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(31,35,40,0.38) 0%, rgba(31,35,40,0.08) 52%, transparent 75%);
  pointer-events: none;
}

.card-badges {
  position: absolute;
  top: 8px;
  left: 10px;
  display: flex;
  gap: 4px;
}

.badge {
  font-size: 9px;
  font-weight: 700;
  padding: 3px 8px;
  border-radius: 6px;
  letter-spacing: 0.5px;
  color: white;
}

.card-target {
  position: absolute;
  bottom: 10px;
  left: 12px;
  font-size: 14px;
  font-weight: 700;
  color: white;
  text-shadow: 0 1px 6px rgba(0,0,0,0.9);
}

.card-body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: start;
  width: 100%;
  box-sizing: border-box;
  padding: 10px 16px;
  gap: 8px;
}

.card-info { flex: 1; min-width: 0; }

.card-name {
  font-size: 14px;
  font-weight: 600;
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: #1f2328;
}

.card-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  gap: 8px;
  margin-top: 4px;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  color: rgba(31,35,40,0.65);
  min-width: 0;
  &.no-time {
    color: rgba(31,35,40,0.45);
    font-style: italic;
  }
}

.chevron {
  flex-shrink: 0;
  transition: transform 0.2s ease;
  &.open { transform: rotate(180deg); }
}

.card-expand {
  padding: 0;
  animation: slideDown 0.2s ease;
  width: 100%;
  box-sizing: border-box;
}

.card-actions {
  display: flex;
  padding: 10px 16px 12px;
  border-bottom: 1px solid rgba(31,35,40,0.12);
  width: 100%;
  box-sizing: border-box;
}

.card-actions .act-btn {
  width: 100%;
  justify-content: center;
  padding: 10px 14px;
  font-size: 13px;
}

.detail-section {
  padding: 12px 16px;
  width: 100%;
  box-sizing: border-box;
  & + .detail-section {
    border-top: 1px solid rgba(31,35,40,0.12);
  }
}

.detail-heading {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: rgba(31,35,40,0.55);
  margin-bottom: 8px;
}

.detail-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  column-gap: 14px;
  row-gap: 0;
  width: 100%;
}

.detail-grid .detail-row {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 2px;
  padding: 8px 0;
  border-bottom: 1px solid rgba(31,35,40,0.1);
  min-width: 0;
}

.detail-grid .detail-label {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.3px;
  color: rgba(31,35,40,0.62);
}

.detail-grid .detail-value {
  font-size: 15px;
  font-weight: 700;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 5px 0;
  width: 100%;
  box-sizing: border-box;
}

.detail-label {
  font-size: 12px;
  color: rgba(31,35,40,0.72);
}

.detail-value {
  font-size: 12px;
  font-weight: 600;
  color: #1f2328;
}

.records-list {
  display: flex;
  flex-direction: column;
  gap: 0;
  width: 100%;
}

.record-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 7px 0;
  border-bottom: 1px solid rgba(31,35,40,0.1);
  &:last-child { border-bottom: none; }
}

.record-name {
  font-size: 12px;
  color: rgba(31,35,40,0.74);
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-right: 8px;
}

.record-time {
  font-size: 12px;
  font-weight: 600;
  color: rgba(31,35,40,0.9);
  white-space: nowrap;
}

.act-btn {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 8px 14px;
  border-radius: 10px;
  border: none;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  font-family: inherit;
  transition: opacity 0.15s ease;
  &:hover { opacity: 0.85; }
  &.route { background: rgba(230,57,70,0.15); color: #e63946; }
}

/* MAP VIEW */
.map-view {
  position: absolute;
  inset: 0;
  overflow: hidden;
}

.map-layers {
  position: absolute;
  inset: 0;
  background: #ffffff;
  touch-action: none;
}

.map-layer {
  position: absolute;
  width: 100%;
  height: 100%;
  pointer-events: none;
}

.marker-layer { pointer-events: all; }

.event-marker {
  cursor: pointer;
  .marker-bg {
    fill: rgba(0,0,0,0.5);
    stroke: none;
    transition: all 0.15s ease;
  }
  .marker-dot {
    stroke: white;
    stroke-width: 1.5;
    transition: all 0.15s ease;
  }
  .marker-label {
    fill: white;
    font-size: 14px;
    font-weight: 700;
    paint-order: stroke;
    stroke: rgba(0,0,0,0.8);
    stroke-width: 4px;
  }
  .marker-count {
    font-size: 16px;
  }
  &.selected {
    .marker-bg {
      fill: rgba(230,57,70,0.3);
      r: 24;
    }
    .marker-dot {
      stroke: #e63946;
      stroke-width: 2.5;
    }
  }
}

/* CAROUSEL */
.map-carousel-wrap {
  position: absolute;
  bottom: 10px;
  left: 0;
  right: 0;
  z-index: 5;
  pointer-events: auto;
}

.map-carousel-viewport {
  overflow: hidden;
  padding: 0 0 30px;
  cursor: grab;
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;
  &:active { cursor: grabbing; }
}

.map-carousel-track {
  display: flex;
  gap: 10px;
  padding-left: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  padding-right: max(0px, calc((100% - var(--carousel-slide-width, 292px)) / 2));
  transition: transform var(--carousel-duration, 0.35s) cubic-bezier(0.25, 0.46, 0.45, 0.94);
  &.no-transition { transition: none; }
}

.map-slide {
  flex-shrink: 0;
  background: rgba(255, 255, 255, 0.96);
  border-radius: 18px;
  overflow: hidden;
  border: 1px solid rgba(31,35,40,0.14);
  box-shadow: 0 8px 20px rgba(31,35,40,0.18);
  pointer-events: auto;
  &.selected {
    border-color: rgba(230,57,70,0.6);
  }
  .act-btn { pointer-events: auto; }
}

.map-slide-img {
  position: relative;
  width: 100%;
  height: 118px;
  background: #ece7dc;
  overflow: hidden;
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
}

.map-slide-img-fade {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(31,35,40,0.38) 0%, rgba(31,35,40,0.08) 52%, transparent 75%);
  pointer-events: none;
}

.map-slide-badges {
  position: absolute;
  top: 6px;
  left: 8px;
  display: flex;
  gap: 4px;
}

.map-slide-body {
  padding: 10px 12px 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.map-slide-top {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.map-slide-name {
  font-size: 14px;
  font-weight: 600;
  color: #1f2328;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
  min-width: 0;
}

.map-slide-meta-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.map-slide-meta {
  display: flex;
  gap: 12px;
  span {
    display: flex;
    align-items: center;
    gap: 3px;
    font-size: 11px;
    color: rgba(31,35,40,0.62);
    &.no-time {
      color: rgba(31,35,40,0.42);
      font-style: italic;
    }
  }
}

.map-slide-meta-row .act-btn {
  flex-shrink: 0;
  padding: 6px 12px;
  font-size: 11px;
}

@keyframes slideDown {
  from { opacity: 0; transform: translateY(-6px); }
  to { opacity: 1; transform: translateY(0); }
}
</style>
