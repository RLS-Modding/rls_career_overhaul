<!--
Map of PhoneFreeroamEvents.vue. This view owns the data lifecycle (events listener, scope acquisition, and the 2 s
fallback to a live screen), list/map selection, the map's selected event, the minimap claim, and mounting the minimap's
own layers into the map view.
- Script, in reading order: imports and constants; state; computed lists; map view (usePhoneMapView); clustering;
  carousel (usePhoneCarousel); selection and actions; map mounting; watchers; lifecycle.
- Children in phoneFreeroamEvents/: FreeroamEventsList (event cards; mounts FreeroamEventDetail for the open card)
  and FreeroamEventsCarousel (bottom card carousel; exposes viewportEl). eventFormat.js holds the pure formatters
  and type tables.
- Children take props and emit events. They never call the bridge or the minimap, and the parent never reaches into
  a child except for the carousel's exposed viewport element.
- Styles: this file keeps the frame, toolbar with its Filter and Sort dropdowns, empty state, and the map container
  with its layers and markers. Each child carries the rules for the elements it renders.
-->
<template>
  <div class="fre-app" v-bng-on-ui-nav:tab_l="event => changePhoneTab(-1, event)" v-bng-on-ui-nav:tab_r="event => changePhoneTab(1, event)">
    <div v-if="!loaded" class="empty-state">
      <p>Loading events...</p>
    </div>

    <template v-if="loaded">
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
            <button class="dropdown-btn" :class="{ active: filterOpen }" @click="toggleFilterPanel">
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
              <button type="button" class="filter-opt" :aria-pressed="filterHasTime" @click="filterHasTime = !filterHasTime">
                <span class="custom-checkbox" :class="{ checked: filterHasTime }"><span class="custom-checkbox-dot"></span></span>

                Has personal best
              </button>
              <button class="filter-clear" @click="clearFilters">Clear</button>
            </div>
          </div>
          <div class="dropdown-wrap">
            <button class="dropdown-btn" :class="{ active: sortOpen }" @click="toggleSortPanel">
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
      <FreeroamEventsList
        v-if="viewMode === 'list'"
        :events="sortedEvents"
        :expanded-id="expandedId"
        :career-active="careerActive"
        :failed-images="failedImages"
        @toggle-expand="toggleExpand"
        @image-error="onImgError"
        @set-route="setRoute"
      />

      <!-- MAP VIEW -->
      <div class="map-view" v-if="viewMode === 'map'" ref="mapContainer"
        v-bng-on-ui-nav:subtab_l="event => mapControl('previous', event)"
        v-bng-on-ui-nav:subtab_r="event => mapControl('next', event)"
        v-bng-on-ui-nav:action_4="event => mapControl('previous', event)"
        v-bng-on-ui-nav:action_3="event => mapControl('next', event)"
        v-bng-on-ui-nav:rotate_h_cam="event => mapControl('pan-x', event)"
        v-bng-on-ui-nav:rotate_v_cam="event => mapControl('pan-y', event)">
        <div
          class="map-layers" role="button" tabindex="0" aria-label="Event map"
          v-bng-on-ui-nav:ok.focusRequired="event => mapControl('zoom-in', event)"
          v-bng-on-ui-nav:context.focusRequired="event => mapControl('zoom-out', event)"
          v-bng-on-ui-nav:focus_l.focusRequired="event => mapControl('left', event)"
          v-bng-on-ui-nav:focus_r.focusRequired="event => mapControl('right', event)"
          v-bng-on-ui-nav:focus_u.focusRequired="event => mapControl('up', event)"
          v-bng-on-ui-nav:focus_d.focusRequired="event => mapControl('down', event)"
          @pointerdown="onMapPointerDown"
          @pointermove="onMapPointerMove"
          @pointerup="onMapPointerUp"
          @pointercancel="onMapPointerUp"
          @pointerleave="onMapPointerUp"
          @wheel.prevent="onMapWheel"
        >
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
        <FreeroamEventsCarousel
          ref="carouselPanel"
          :slides="carouselEvents"
          :slide-offset="carouselOffset"
          :slide-width="carouselSlideWidth"
          :transition-duration="carouselTransitionDuration"
          :is-dragging="isDraggingCarousel"
          :is-wrapping="isWrappingCarousel"
          :selected-event="selectedEvent"
          :failed-images="failedImages"
          @viewport-pointer-down="onCarouselPointerDown"
          @viewport-click="onCarouselViewportClick"
          @image-error="onImgError"
          @set-route="setRoute"
        />
      </div>
    </template>
  </div>
</template>

<script setup>

import { usePhoneAppFocus } from './controllerLayers.js'
import { usePhoneScreen } from '../../composables/usePhoneScreen'

import { nextTab } from '../../utils/controllerTabs.js'
import { vBngOnUiNav } from '@/common/directives'
import { ref, reactive, computed, onMounted, onUnmounted, watch, nextTick } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { useMinimapStore } from '../../stores/minimapStore'
import { acquireScope } from '../../utils/luaScopes'
import { safeLua } from '../../utils/safeLua'
import { usePhoneCarousel } from '../../composables/usePhoneCarousel'
import { clusterPhoneMapItems, usePhoneMapView } from '../../composables/usePhoneMapView'
import FreeroamEventsList from '../phoneFreeroamEvents/FreeroamEventsList.vue'
import FreeroamEventsCarousel from '../phoneFreeroamEvents/FreeroamEventsCarousel.vue'
import { bestValue, personalBest, isScoreEvent, ensureTypesArray, getEventColor, typeColors, typeLabels } from '../phoneFreeroamEvents/eventFormat.js'

usePhoneAppFocus()

function changePhoneTab(direction, event) {

  event?.stopPropagation()
  const next = nextTab([{ id: 'list' }, { id: 'map' }], viewMode.value, direction)
  if (next) viewMode.value = next.id
}


// The screen shows "Loading events..." until the first payload arrives; after this long it goes live without data.
const LOADED_FALLBACK_MS = 2000
// The minimap names this screen as the owner of its view while the map is open.
const MAP_OWNER_ID = 'freeroamEvents'
const CLUSTER_RADIUS_PX = 50
// Unknown distances and best times sort after every known value.
const UNKNOWN_SORT_VALUE = 1e9

const sortFields = [
  { key: 'name', label: 'Name' },
  { key: 'distance', label: 'Distance' },
  { key: 'bestTime', label: 'Best Time' },
  { key: 'reward', label: 'Reward' },
]

const events = useEvents()
const minimapStore = useMinimapStore()
const {
  mapContainer, markerViewBox, baseViewBox: freBaseViewBox, panOffset, zoomFactor, panState,
  suppressMarkerClickUntil, parseViewBox, buildWalkingZoomBaseViewBox, getMapBaseViewBox,
  applyEffectiveViewBox, stopMapFocusAnimation, animateMapPanTo,
  onMapWheel, onMapPointerDown, onMapPointerMove, onMapPointerUp,
} = usePhoneMapView({ minimapStore, ownerId: MAP_OWNER_ID })

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
usePhoneScreen({ onBack: () => { if (filterOpen.value || sortOpen.value) { filterOpen.value = false; sortOpen.value = false; return true } if (expandedId.value) { expandedId.value = null; return true } return false } })
const sortBy = ref('name')
const sortAsc = ref(true)
const filterHasTime = ref(false)
const activeTypeFilters = reactive(new Set())
const failedImages = reactive(new Set())

let resizeObserver = null
let carouselResizeObserver = null

const carouselPanel = ref(null)
const carouselViewportRef = computed(() => carouselPanel.value?.viewportEl ?? null)
const carouselWidth = ref(340)
const mapContainerSize = ref({ width: 400, height: 400 })

const eventsList = computed(() => {
  const val = eventsData.value
  if (Array.isArray(val)) return val
  if (val && typeof val === 'object') return Object.values(val)
  return []
})

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
    list = list.filter(ev => ev.isDemoEvent ? ev.demoStats?.runs > 0 : ev.isPulling ? ev.currentVehicleBestPullDistance > 0 : bestValue(ev) !== 'No result yet')
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
        va = a.distance < 0 ? UNKNOWN_SORT_VALUE : a.distance
        vb = b.distance < 0 ? UNKNOWN_SORT_VALUE : b.distance
        break
      case 'bestTime':
        va = !isScoreEvent(a) && !a.hasTopSpeed ? personalBest(a).time ?? UNKNOWN_SORT_VALUE : UNKNOWN_SORT_VALUE
        vb = !isScoreEvent(b) && !b.hasTopSpeed ? personalBest(b).time ?? UNKNOWN_SORT_VALUE : UNKNOWN_SORT_VALUE
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

function clusterEvents(events, viewBoxStr, containerSize) {
  return clusterPhoneMapItems(events, viewBoxStr, containerSize, {
    keyOf: ev => ev.raceName,
    xOf: ev => ev.position.x,
    yOf: ev => ev.position.y,
    radiusPx: CLUSTER_RADIUS_PX,
  })
}

const clusteredMarkers = computed(() =>
  clusterEvents(eventsWithPos.value, markerViewBox.value, mapContainerSize.value)
)

// Slides sit inside the viewport with this inset on each side, and never shrink below the minimum width.
const CAROUSEL_SIDE_INSET = 14
const CAROUSEL_MIN_SLIDE_WIDTH = 292
const carouselSlideWidth = computed(() => Math.max(CAROUSEL_MIN_SLIDE_WIDTH, carouselWidth.value - CAROUSEL_SIDE_INSET * 2))
const carousel = usePhoneCarousel({
  items: filteredEvents,
  slideWidth: carouselSlideWidth,
  viewportRef: carouselViewportRef,
  onSelect: ev => { selectedEvent.value = ev },
})
const {
  slides: carouselEvents,
  slideOffset: carouselOffset,
  transitionDuration: carouselTransitionDuration,
  isDragging: isDraggingCarousel,
  isWrapping: isWrappingCarousel,
} = carousel
const onCarouselPointerDown = carousel.onPointerDown

function toggleFilterPanel() {
  filterOpen.value = !filterOpen.value
  sortOpen.value = false
}

function toggleSortPanel() {
  sortOpen.value = !sortOpen.value
  filterOpen.value = false
}

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

// Reuse the existing map surface: controller actions must not add map chrome.
function mapControl(action, event) {
  event?.stopPropagation()
  if (action === 'previous') stepMapEvent(-1)
  else if (action === 'next') stepMapEvent(1)
  else if (action === 'zoom-in') zoomMap(1.25)
  else if (action === 'zoom-out') zoomMap(0.8)
  else if (['left', 'right', 'up', 'down'].includes(action)) panMap(action)
  else {
    const value = Number(event?.detail?.value) || 0
    if (Math.abs(value) < 0.1) return
    panMap(action === 'pan-x' ? (value < 0 ? 'left' : 'right') : (value < 0 ? 'up' : 'down'), Math.abs(value))
  }
}
function stepMapEvent(direction) {
  const items = filteredEvents.value
  if (!items.length) return
  const index = items.findIndex(ev => ev.raceName === selectedEvent.value?.raceName)
  focusEvent(items[(index + direction + items.length) % items.length], { centerMap: true })
}
function zoomMap(factor) {
  stopMapFocusAnimation()
  zoomFactor.value = Math.max(0.1, Math.min(4, zoomFactor.value * factor))
  applyEffectiveViewBox()
}
function panMap(direction, strength = 1) {
  stopMapFocusAnimation()
  const base = getMapBaseViewBox()
  const amount = strength * Math.max(base.w, base.h) / (8 * zoomFactor.value)
  if (direction === 'left') panOffset.x -= amount
  if (direction === 'right') panOffset.x += amount
  if (direction === 'up') panOffset.y -= amount
  if (direction === 'down') panOffset.y += amount
  applyEffectiveViewBox()
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
  if (lua.overhaul_phone_apps_freeroamEvents?.navigateToEvent) {
    await lua.overhaul_phone_apps_freeroamEvents.navigateToEvent(raceName)
  }
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

// Carousel logic
function scrollToEventCard(raceName) {
  if (!raceName) return
  const index = filteredEvents.value.findIndex(e => e.raceName === raceName)
  if (index < 0) return
  carousel.scrollToItem(index)
}

function onCarouselViewportClick(event) {
  const ev = carousel.itemAtClick(event)
  if (ev) focusEvent(ev, { centerMap: true, animateCenterMap: true })
}

function initCarouselScroll() {
  const list = filteredEvents.value
  const selectedIndex = selectedEvent.value ? list.findIndex(e => e.raceName === selectedEvent.value.raceName) : -1
  carousel.snapToItem(Math.max(0, selectedIndex))
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

let mapView = null

function initMap() {
  if (!mapContainer.value) return
  mapView?.dispose()
  const host = mapContainer.value.querySelector('.map-layers')
  if (host) {
    mapView = minimapStore.mountMap(host)
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
  if (viewMode.value !== 'map' || !loaded.value) return
  await nextTick()
  initMap()
}

watch([viewMode, careerActive, loaded], async ([newViewMode], [oldViewMode]) => {
  let shouldCenterNearestOnOpen = false
  if (viewMode.value !== 'map') {
    mapView?.dispose()
    mapView = null
    selectedEvent.value = null
    minimapStore.viewControlledBy = null
    minimapStore.showTerrainImage = true
  } else {
    filterOpen.value = false
    sortOpen.value = false
    if (oldViewMode !== 'map') {
      freBaseViewBox.value = buildWalkingZoomBaseViewBox()
    }
    minimapStore.viewControlledBy = MAP_OWNER_ID
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
  if (minimapStore.viewControlledBy === MAP_OWNER_ID) return
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
  minimapStore.acquire()

  events.on('phoneFreeroamEventsData', (data) => {
    failedImages.clear()
    careerActive.value = data.careerActive === true
    eventsData.value = data.events || {}
    levelId.value = data.levelId || ''
    currentVehicleName.value = data.currentVehicleName || ''
    loaded.value = true
    mountMapIfVisible()
  })

  // A failed scope request goes live without data; safeLua logs it once and returns undefined.
  const requested = await safeLua(async () => {
    await acquireScope(lua, 'phone.freeroamEvents')
    if (lua.overhaul_phone_apps_freeroamEvents?.getEventsData) {
      lua.overhaul_phone_apps_freeroamEvents.getEventsData()
    } else {
      loaded.value = true
    }
    return true
  }, 'Request freeroam events')
  if (!requested) loaded.value = true

  setTimeout(() => { if (!loaded.value) loaded.value = true }, LOADED_FALLBACK_MS)
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
  mapView?.dispose()
  minimapStore.release()
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
  font-family: inherit; padding: 0; border: 0; background: transparent; text-align: left;
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

/* MAP VIEW */
.map-view {
  position: absolute;
  inset: 0;
  // Keep map layers below the sibling toolbar, including their hit targets.
  isolation: isolate;
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

.marker-layer {
  z-index: 1; pointer-events: all; }

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
</style>
