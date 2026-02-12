<template>
  <PhoneWrapper app-name="Events" status-font-color="#FFFFFF" status-blend-mode="normal">
    <div class="fre-app">
      <!-- Not in career -->
      <div v-if="!careerActive && loaded" class="empty-state">
        <p>Start a career to view events.</p>
      </div>

      <!-- Loading -->
      <div v-if="!loaded" class="empty-state">
        <p>Loading events...</p>
      </div>

      <!-- No events -->
      <div v-if="careerActive && loaded && eventsList.length === 0" class="empty-state">
        <p>No freeroam events found on this map.</p>
      </div>

      <template v-if="careerActive && loaded && eventsList.length > 0">
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
            <div class="card-row">
              <div class="card-thumb">
                <img v-if="!imgFailed(ev.raceName)" :src="ev.thumbnail" alt="" @error="onImgError(ev.raceName)" />
                <div v-else class="card-thumb-ph">
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
                </div>
              </div>
              <div class="card-info">
                <span class="card-name">{{ ev.label }}</span>
                <div class="card-badges">
                  <span
                    v-for="t in ev.types"
                    :key="t"
                    class="type-badge"
                    :style="{ '--badge-color': typeColors[t] || '#888' }"
                  >{{ typeLabels[t] || t }}</span>
                </div>
                <div class="card-meta">
                  <span class="meta-item" v-if="ev.currentVehicleBestTime">
                    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
                    {{ formatTime(ev.currentVehicleBestTime) }}
                  </span>
                  <span class="meta-item no-time" v-else>No time set</span>
                  <span class="meta-item target">
                    Target: {{ formatTime(ev.bestTime) }}
                  </span>
                  <span class="meta-item" v-if="ev.distance >= 0">
                    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="10" r="3"/><path d="M12 21.7C17.3 17 20 13 20 10a8 8 0 10-16 0c0 3 2.7 7 8 11.7z"/></svg>
                    {{ formatDistance(ev.distance) }}
                  </span>
                </div>
              </div>
              <svg class="chevron" :class="{ open: expandedId === ev.raceName }" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.35)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
            </div>

            <!-- Expanded detail -->
            <div class="card-expand" v-if="expandedId === ev.raceName" @click.stop>
              <div class="detail-section">
                <div class="detail-row">
                  <span class="detail-label">Target Time</span>
                  <span class="detail-value">{{ formatTime(ev.bestTime) }}</span>
                </div>
                <div class="detail-row">
                  <span class="detail-label">Base Reward</span>
                  <span class="detail-value">${{ formatPrice(ev.reward) }}</span>
                </div>
                <div class="detail-row" v-if="ev.hotlap">
                  <span class="detail-label">Hotlap Target</span>
                  <span class="detail-value">{{ formatTime(ev.hotlap) }}</span>
                </div>
                <div class="detail-row" v-if="ev.hasDamageFactor">
                  <span class="detail-label">Damage Factor</span>
                  <span class="detail-value">{{ Math.round(ev.damageFactor * 100) }}%</span>
                </div>
                <div class="detail-row" v-if="ev.hasTopSpeed && ev.topSpeedGoal">
                  <span class="detail-label">Target Speed</span>
                  <span class="detail-value">{{ ev.topSpeedGoal.toFixed(1) }} mph</span>
                </div>
                <div class="detail-row" v-if="ev.hasDrift && ev.driftGoal">
                  <span class="detail-label">Drift Goal</span>
                  <span class="detail-value">{{ ev.driftGoal.toLocaleString() }} pts</span>
                </div>
              </div>

              <!-- Alt Route -->
              <div class="detail-section" v-if="ev.hasAltRoute">
                <div class="detail-heading">Alternative Route</div>
                <div class="detail-row">
                  <span class="detail-label">{{ ev.altRouteLabel }}</span>
                  <span class="detail-value">{{ formatTime(ev.altRouteBestTime) }} · ${{ formatPrice(ev.altRouteReward) }}</span>
                </div>
              </div>

              <!-- Current vehicle -->
              <div class="detail-section">
                <div class="detail-heading">Current Vehicle</div>
                <div class="detail-row">
                  <span class="detail-label">{{ ev.currentVehicleName || 'No Vehicle' }}</span>
                  <span class="detail-value">{{ ev.currentVehicleBestTime ? formatTime(ev.currentVehicleBestTime) : 'No time' }}</span>
                </div>
              </div>

              <!-- Vehicle records -->
              <div class="detail-section" v-if="ev.vehicleRecords && ev.vehicleRecords.length > 0">
                <div class="detail-heading">All Records</div>
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

              <div class="card-actions">
                <button class="act-btn route" @click.stop="setRoute(ev.raceName)">
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
                  Set Route
                </button>
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
            <svg class="map-layer marker-layer" :viewBox="markerViewBox">
              <g v-for="ev in eventsWithPos" :key="'m-' + ev.raceName"
                :transform="'translate(' + (-ev.position.x) + ',' + ev.position.y + ') scale(' + zoomFactor + ')'"
                class="event-marker"
                :class="{ selected: selectedEvent && selectedEvent.raceName === ev.raceName }"
                @click.stop="selectEvent(ev)"
              >
                <circle r="18" class="marker-bg" />
                <circle r="12" class="marker-dot" :style="{ fill: getEventColor(ev) }" />
                <text y="28" text-anchor="middle" class="marker-label">{{ ev.label }}</text>
              </g>
            </svg>
          </div>

          <!-- Selected event card overlay -->
          <div class="map-selected-card" v-if="selectedEvent" @click="expandedId = selectedEvent.raceName; viewMode = 'list'">
            <div class="card-thumb small">
              <img v-if="!imgFailed(selectedEvent.raceName)" :src="selectedEvent.thumbnail" alt="" @error="onImgError(selectedEvent.raceName)" />
              <div v-else class="card-thumb-ph">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="1.5"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>
              </div>
            </div>
            <div class="card-info">
              <span class="card-name">{{ selectedEvent.label }}</span>
              <div class="card-badges">
                <span v-for="t in selectedEvent.types" :key="t" class="type-badge" :style="{ '--badge-color': typeColors[t] || '#888' }">{{ typeLabels[t] || t }}</span>
              </div>
              <span class="meta-item" v-if="selectedEvent.currentVehicleBestTime">{{ formatTime(selectedEvent.currentVehicleBestTime) }}</span>
              <span class="meta-item no-time" v-else>No time</span>
            </div>
            <button class="act-btn route compact" @click.stop="setRoute(selectedEvent.raceName)">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polygon points="3 11 22 2 13 21 11 13 3 11"/></svg>
            </button>
          </div>
        </div>
      </template>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onUnmounted, watch } from 'vue'
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
const markerViewBox = ref('-2000 -2000 4000 4000')
const panOffset = reactive({ x: 0, y: 0 })
const zoomFactor = ref(1)
const panState = reactive({ active: false, moved: false, lastX: 0, lastY: 0, pointerId: null })

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
  return Object.values(eventsData.value)
})

const allTypes = computed(() => {
  const types = new Set()
  eventsList.value.forEach(ev => {
    if (ev.types) ev.types.forEach(t => types.add(t))
  })
  return [...types].sort()
})

const filteredEvents = computed(() => {
  let list = eventsList.value
  if (activeTypeFilters.size > 0) {
    list = list.filter(ev => ev.types && ev.types.some(t => activeTypeFilters.has(t)))
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
  return eventsList.value.filter(ev => ev.position && ev.position.x !== undefined)
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
  if (m < 0) return '?'
  if (m < 1000) return m + 'm'
  return (m / 1000).toFixed(1) + 'km'
}

function getEventColor(ev) {
  if (ev.types && ev.types.length > 0) {
    return typeColors[ev.types[0]] || '#888'
  }
  return '#888'
}

function imgFailed(id) { return failedImages.has(id) }
function onImgError(id) { failedImages.add(id) }

function toggleExpand(id) {
  expandedId.value = expandedId.value === id ? null : id
}

function toggleTypeFilter(type) {
  if (activeTypeFilters.has(type)) {
    activeTypeFilters.delete(type)
  } else {
    activeTypeFilters.add(type)
  }
}

function clearFilters() {
  activeTypeFilters.clear()
  filterHasTime.value = false
}

function selectEvent(ev) {
  selectedEvent.value = selectedEvent.value?.raceName === ev.raceName ? null : ev
}

async function setRoute(raceName) {
  if (lua.ui_phone_freeroamEvents?.navigateToEvent) {
    await lua.ui_phone_freeroamEvents.navigateToEvent(raceName)
  }
}

// Map pan/zoom
function onMapPointerDown(e) {
  if (panState.active) return
  panState.active = true
  panState.moved = false
  panState.lastX = e.clientX
  panState.lastY = e.clientY
  panState.pointerId = e.pointerId
  e.target.setPointerCapture?.(e.pointerId)
}

function onMapPointerMove(e) {
  if (!panState.active || e.pointerId !== panState.pointerId) return
  const dx = e.clientX - panState.lastX
  const dy = e.clientY - panState.lastY
  if (Math.abs(dx) > 2 || Math.abs(dy) > 2) panState.moved = true
  panOffset.x += dx
  panOffset.y += dy
  panState.lastX = e.clientX
  panState.lastY = e.clientY
  updateMarkerViewBox()
}

function onMapPointerUp(e) {
  if (e.pointerId !== panState.pointerId) return
  panState.active = false
}

function onMapWheel(e) {
  const delta = e.deltaY > 0 ? 1.15 : 0.87
  zoomFactor.value = Math.max(0.2, Math.min(5, zoomFactor.value * delta))
  updateMarkerViewBox()
}

function updateMarkerViewBox() {
  const events = eventsWithPos.value
  if (events.length === 0) {
    markerViewBox.value = '-2000 -2000 4000 4000'
    return
  }
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const ev of events) {
    const x = -ev.position.x
    const y = ev.position.y
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }
  const pad = 200 / zoomFactor.value
  const w = Math.max(maxX - minX + pad * 2, 500)
  const h = Math.max(maxY - minY + pad * 2, 500)
  const cx = (minX + maxX) / 2 - panOffset.x / zoomFactor.value
  const cy = (minY + maxY) / 2 - panOffset.y / zoomFactor.value
  markerViewBox.value = `${cx - w / 2} ${cy - h / 2} ${w} ${h}`
}

onMounted(async () => {
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
    updateMarkerViewBox()
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
})

onUnmounted(() => {
  // Extension cleanup handled by phone system
})
</script>

<style scoped lang="scss">
.fre-app {
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

.empty-state {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  text-align: center;
  color: rgba(255, 255, 255, 0.4);
  font-size: 13px;
  padding: 20px;
  &.small {
    height: auto;
    padding: 30px 20px;
  }
}

/* Toolbar */
.toolbar {
  flex-shrink: 0;
  padding: 8px 10px 4px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  background: rgba(0, 0, 0, 0.3);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
}

.view-toggle {
  display: flex;
  gap: 4px;
  background: rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  padding: 2px;
  button {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 5px;
    padding: 6px 0;
    border: none;
    background: transparent;
    color: rgba(255, 255, 255, 0.5);
    font-size: 12px;
    font-weight: 600;
    border-radius: 6px;
    cursor: pointer;
    transition: all 0.2s;
    &.active {
      background: rgba(255, 255, 255, 0.12);
      color: #fff;
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
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
}

.dropdown-wrap {
  position: relative;
}

.dropdown-btn {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.04);
  color: rgba(255, 255, 255, 0.65);
  font-size: 11px;
  cursor: pointer;
  &.active {
    border-color: rgba(255, 255, 255, 0.2);
    color: #fff;
  }
}

.dropdown-chevron {
  transition: transform 0.2s;
  &.open { transform: rotate(180deg); }
}

.dropdown-panel {
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  z-index: 20;
  min-width: 160px;
  padding: 8px;
  background: rgba(30, 30, 36, 0.97);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 10px;
  backdrop-filter: blur(20px);
}

.sort-grid {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 6px 8px;
  align-items: center;
}

.sort-label {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.4);
}

.sort-options {
  display: flex;
  gap: 3px;
  flex-wrap: wrap;
}

.sort-opt {
  padding: 3px 8px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 5px;
  background: transparent;
  color: rgba(255, 255, 255, 0.5);
  font-size: 11px;
  cursor: pointer;
  &.active {
    background: rgba(255, 255, 255, 0.12);
    color: #fff;
    border-color: rgba(255, 255, 255, 0.2);
  }
}

.filter-panel {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 200px;
}

.filter-types {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
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

.filter-opt {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.65);
  cursor: pointer;
}

.custom-checkbox {
  width: 14px;
  height: 14px;
  border: 1.5px solid rgba(255, 255, 255, 0.25);
  border-radius: 3px;
  display: flex;
  align-items: center;
  justify-content: center;
  &.checked {
    background: #e63946;
    border-color: #e63946;
    .custom-checkbox-dot {
      display: block;
    }
  }
}

.custom-checkbox-dot {
  display: none;
  width: 6px;
  height: 6px;
  background: white;
  border-radius: 1px;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
}

.filter-clear {
  padding: 4px 8px;
  border: none;
  border-radius: 5px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.5);
  font-size: 11px;
  cursor: pointer;
  align-self: flex-start;
}

/* List view */
.list-view {
  flex: 1;
  overflow-y: auto;
  padding: 6px 8px 20px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  -webkit-overflow-scrolling: touch;
}

.card {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 12px;
  overflow: hidden;
  cursor: pointer;
  transition: border-color 0.2s;
  &:active {
    border-color: rgba(255, 255, 255, 0.15);
  }
}

.card-row {
  display: flex;
  align-items: center;
  padding: 8px;
  gap: 10px;
}

.card-thumb {
  width: 60px;
  height: 60px;
  border-radius: 8px;
  overflow: hidden;
  flex-shrink: 0;
  background: rgba(255, 255, 255, 0.04);
  img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &.small {
    width: 44px;
    height: 44px;
    border-radius: 6px;
  }
}

.card-thumb-ph {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}

.card-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.card-name {
  font-size: 13px;
  font-weight: 600;
  color: #fff;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.card-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 3px;
}

.type-badge {
  display: inline-flex;
  padding: 1px 6px;
  border-radius: 4px;
  font-size: 9px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.3px;
  background: var(--badge-color);
  color: #fff;
}

.card-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  align-items: center;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 3px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.55);
  &.no-time {
    color: rgba(255, 255, 255, 0.3);
    font-style: italic;
  }
  &.target {
    color: rgba(255, 255, 255, 0.4);
  }
}

.chevron {
  flex-shrink: 0;
  transition: transform 0.2s;
  &.open {
    transform: rotate(180deg);
  }
}

/* Expanded detail */
.card-expand {
  padding: 0 10px 10px;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
}

.detail-section {
  padding: 8px 0;
  & + .detail-section {
    border-top: 1px solid rgba(255, 255, 255, 0.04);
  }
}

.detail-heading {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: rgba(255, 255, 255, 0.35);
  margin-bottom: 4px;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 2px 0;
}

.detail-label {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.6);
}

.detail-value {
  font-size: 12px;
  font-weight: 600;
  color: #fff;
}

.records-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.record-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 3px 0;
}

.record-name {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.55);
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-right: 8px;
}

.record-time {
  font-size: 11px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.8);
  white-space: nowrap;
}

.card-actions {
  display: flex;
  gap: 6px;
  padding-top: 8px;
}

.act-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 7px 14px;
  border: none;
  border-radius: 8px;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity 0.15s;
  &:active { opacity: 0.7; }
  &.route {
    background: #e63946;
    color: #fff;
  }
  &.compact {
    padding: 6px 10px;
    border-radius: 6px;
  }
}

/* Map view */
.map-view {
  flex: 1;
  position: relative;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.4);
}

.map-layers {
  width: 100%;
  height: 100%;
  touch-action: none;
}

.map-layer {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
}

.event-marker {
  cursor: pointer;
  .marker-bg {
    fill: rgba(0, 0, 0, 0.5);
    stroke: none;
  }
  .marker-dot {
    stroke: rgba(255, 255, 255, 0.3);
    stroke-width: 1.5;
  }
  .marker-label {
    fill: rgba(255, 255, 255, 0.7);
    font-size: 10px;
    font-weight: 600;
    pointer-events: none;
  }
  &.selected {
    .marker-bg {
      fill: rgba(230, 57, 70, 0.3);
    }
    .marker-dot {
      stroke: #e63946;
      stroke-width: 2;
    }
    .marker-label {
      fill: #fff;
    }
  }
}

.map-selected-card {
  position: absolute;
  bottom: 12px;
  left: 10px;
  right: 10px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px;
  background: rgba(30, 30, 36, 0.95);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 12px;
  backdrop-filter: blur(15px);
  cursor: pointer;
}
</style>
