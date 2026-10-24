<template>

    <div ref="homescreenRef" class="homescreen" :style="baseBackgroundStyle" v-bng-on-ui-nav:context="openTileMenu" v-bng-on-ui-nav:tab_l="() => goToPage(currentPageIndex - 1)" v-bng-on-ui-nav:tab_r="() => goToPage(currentPageIndex + 1)">
      <!-- Pages container -->
      <div
        ref="viewportRef"
        class="pages-viewport"
        @pointerdown="onViewportPointerDown"
        @pointermove="onViewportPointerMove"
        @pointerup="onViewportPointerUp"
        @pointercancel="onViewportPointerUp"
      >
        <div
          class="pages-track"
          :class="{ 'no-transition': isDraggingPage || (isDraggingIcon && !isEdgePaging) }"
          :style="{ transform: `translateX(${pageOffset}px)` }"
        >
          <!-- App pages -->
          <div
            v-for="(page, pageIdx) in pages"
            :key="'page-' + pageIdx"
            class="page apps-page" :inert="currentPageIndex !== pageIdx" :bng-no-child-nav="currentPageIndex !== pageIdx"
            :style="appsPageStyle"
          >
            <div class="app-grid">
              <div
                v-for="(app, slotIdx) in page"
                :key="app ? app.id : 'empty-' + pageIdx + '-' + slotIdx"
                class="grid-slot"
                :data-page="pageIdx"
                :data-slot="slotIdx"
                :role="movingApp ? 'button' : null" :tabindex="movingApp ? 0 : null" :bng-nav-item="movingApp ? '' : null"
                :aria-label="movingApp ? (app ? `Swap with ${app.name}` : `Place in slot ${slotIdx + 1}`) : null"
                @click="movingApp && placeApp({ type: 'grid', page: pageIdx, slot: slotIdx })"
              >
                <PhoneAppIcon
                  v-if="app && !(isDraggingIcon && dragSourceApp?.id === app.id)" :inert="!!movingApp"
                  :app="app"
                  :class="{ 'app-launch-pending': pressedAppId === app.id }"
                  :jiggle-mode="jiggleMode"
                  :jiggle-offset="(pageIdx * 20 + slotIdx) % 7"
                  :is-new="!seenApps.has(app.id)"
                  :tutorial-data-id="`homescreen-${app.id}`"
                  :tutorial-highlighted="tutorialHighlightAppId === app.id"
                  :tutorial-blocked="tutorialBlockLaunches && !isLaunchAllowed(app.id)"
                  @launch="launchApp"
                  @longpress="enterJiggleMode"
                  @dragstart="onGridDragStart"
                  @remove="onRemoveApp"
                />
              </div>
            </div>
          </div>

          <!-- Search page -->
          <div
            class="page search-page" :inert="!isSearchPageActive || !!movingApp" :bng-no-child-nav="!isSearchPageActive || !!movingApp"
            :class="{ 'no-transition': isDraggingPage || (isDraggingIcon && !isEdgePaging) }"
            :style="listScreenStyle"
          >
            <PhoneSearch
              :apps="availableApps"
              :seen-apps="seenApps"
              :jiggle-mode="jiggleMode"
              :app-ids-on-home="appIdsOnHome"
              @launch="launchApp"
              @dragstart="onSearchDragStart"
            />
          </div>
        </div>
      </div>

      <!-- Dock (with integrated page dots) -->
      <PhoneDock
        ref="dockRef"
        :dock-ids="dockIds" :moving="!!movingApp" @place="slot => placeApp({ type: 'dock', slot })"
        :app-map="appMap"
        :jiggle-mode="jiggleMode"
        :highlight-index="dockHighlightIdx"
        :total-pages="pages.length"
        :current-page="currentPageIndex"
        :is-search-active="isSearchPageActive"
        :slide-offset="dockSlideOffset"
        :no-transition="isDraggingPage || (isDraggingIcon && !isEdgePaging)"
        :background-image="phoneSettings.backgroundImage || ''"
        :tutorial-highlight-app-id="tutorialHighlightAppId"
        :tutorial-block-launches="tutorialBlockLaunches"
        :tutorial-launch-app-id="tutorialLaunchAppId"
        @launch="launchApp"
        @longpress="enterJiggleMode"
        @dragstart="onDockDragStart"
        @go-page="goToPage"
        @remove="onRemoveApp"
      />

      <PhoneLayer v-if="tileMenuApp" class="tile-menu" label="App actions" @close="tileMenuApp = null">
        <strong>{{ tileMenuApp.name }}</strong>
        <button type="button" bng-scoped-nav-autofocus @click="openMenuApp">Open</button>
        <button type="button" @click="pinMenuApp">Pin to dock</button>
        <button type="button" @click="startMove">Move</button>
        <button v-if="!SYSTEM_APP_IDS.has(tileMenuApp.id)" type="button" @click="removeMenuApp">Remove</button>
        <button type="button" @click="tileMenuApp = null">Cancel</button>
      </PhoneLayer>
      <!-- Drag ghost -->
      <div
        v-if="isDraggingIcon && dragGhostApp"
        class="drag-ghost"
        :style="{ transform: `translate(${dragGhostPos.x}px, ${dragGhostPos.y}px)` }"
      >
        <PhoneAppIcon :app="dragGhostApp" :show-label="false" :is-drag-ghost="true" />
      </div>

      <!-- Jiggle mode Done button -->
      <button v-if="jiggleMode" class="done-btn" @click="exitJiggleMode">Done</button>

    </div>

</template>

<script setup>
import PhoneLayer from '../../components/phone/PhoneLayer.vue'
import { placeHomeApp } from '../../components/phone/phoneHomePlacement.js'
import { createPhonePageGestures } from './createPhonePageGestures.js'
import { reportUiFailure } from "../../utils/safeLua"

import { ref, computed, onMounted, onActivated, onUnmounted, reactive, watch, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { vBngOnUiNav } from '@/common/directives'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import PhoneAppIcon from '../../components/phone/PhoneAppIcon.vue'
import PhoneDock from '../../components/phone/PhoneDock.vue'
import PhoneSearch from '../../components/phone/PhoneSearch.vue'
import { usePhoneApps } from '../../utils/phoneAppRegistry'
import { isPhoneAppCatalogLoaded, onPhoneAppsChanged } from '../../utils/phoneAppCatalog'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'
import { usePhoneSettings } from '../../composables/usePhoneSettings'
import { usePhoneTutorial, PHONE_TUTORIAL_STEPS } from '../../composables/usePhoneTutorial'
import {
  PREINSTALLED_APP_IDS,
  SYSTEM_APP_IDS,
  DEFAULT_HOME_APPS,
  collectInstalledFromLayout,
  LAYOUT_VERSION,
  toSlotArray,
  toIdList,
} from '../../utils/phoneLayoutUtils'
import { readPhoneLayoutCache, writePhoneLayoutCache } from '../../utils/phoneLayoutCache'
import { acquireScope } from '../../utils/luaScopes'
import { readPhoneShellState } from '../../utils/phoneShellState'

const PAGE_WIDTH = 360

const router = useRouter()
const phoneScreen = usePhoneScreen({ onBack: handleBack, hideCash: () => jiggleMode.value })
const pressedAppId = ref(null)
function iconVisual(appId) {
  const candidates = homescreenRef.value?.querySelectorAll('[data-app-id]') || []
  const icon = [...candidates].find(element => element.dataset.appId === appId)
  const tile = icon?.querySelector('.app-icon-square')
  if (!tile) return null
  const rect = tile.getBoundingClientRect()
  const viewport = homescreenRef.value.getBoundingClientRect()
  if (rect.right <= viewport.left || rect.left >= viewport.right || rect.width === 0) return null
  return { rect, color: getComputedStyle(tile).backgroundColor, image: tile.querySelector('img')?.src || null }
}
const disposeIconVisual = phoneScreen?.registerIconVisual(iconVisual)
const disposeNavigation = router.afterEach(() => { pressedAppId.value = null })
const events = useEvents()
const {
  availableApps,
  catalogApps,
  refreshApps,
  setInstalledApps,
  DEFAULT_DOCK_IDS,
  APPS_PER_PAGE,
} = usePhoneApps()
const { phoneSettings, replacePhoneSettings, getPhoneSettingsSnapshot } = usePhoneSettings()
const phoneTutorial = usePhoneTutorial()
const {
  tutorialHighlightAppId,
  tutorialBlockLaunches,
  tutorialLaunchAppId,
  isLaunchAllowed,
  notifyDockReady,
  advanceAfterGuideTap,
  advanceAfterEmploymentTap,
  advanceAfterVehicleTransferTap,
  stepIndex: phoneStepIndex,
} = phoneTutorial

// Default home screen: the manifests' defaultHome slots. DEFAULT_HOME_APPS and DEFAULT_DOCK_IDS are live manifest arrays, read when called.
function buildDefaultLayout() {
  const page = new Array(APPS_PER_PAGE).fill(null)
  for (const entry of DEFAULT_HOME_APPS) {
    if (entry.slot < APPS_PER_PAGE && page[entry.slot] === null) page[entry.slot] = entry.id
  }
  return [page]
}

function normalizeDockIds(ids) {
  const dock = Array.isArray(ids) ? [...ids].slice(0, 4) : [...DEFAULT_DOCK_IDS]
  while (dock.length < 4) dock.push(null)
  return dock.map(v => (v && v !== '') ? v : null)
}

// Manifest defaults are filled in place after discovery.

const layoutCache = readPhoneLayoutCache()
const shellState = readPhoneShellState()
// Built when used: the preinstalled and default home apps come from the discovered app manifests.
const defaultInstalledIds = () => [...PREINSTALLED_APP_IDS, ...DEFAULT_HOME_APPS.map(entry => entry.id)]

// Layout state — hydrate from cache/defaults so grid icons render with the dock (no Lua wait).
const dockIds = ref(normalizeDockIds(layoutCache?.dockIds))
const pageLayouts = ref(
  layoutCache?.pageLayouts?.length
    ? layoutCache.pageLayouts.map(page => [...page])
    : buildDefaultLayout()
)
const installedAppIds = ref(
  layoutCache?.installedAppIds?.length ? [...layoutCache.installedAppIds] : defaultInstalledIds()
)
const seenApps = ref(new Set(layoutCache?.seenApps || []))
const removedAppIds = ref(new Set(layoutCache?.removedAppIds || []))
const wallpaper = ref(layoutCache?.wallpaper || 'default')
setInstalledApps(shellState?.layout ? toIdList(shellState.layout.installedAppIds) : installedAppIds.value, shellState?.careerActive)
const currentPageIndex = ref(0)

// Jiggle mode
const jiggleMode = ref(false)

// Page dragging
const isDraggingPage = ref(false)
const pagePointerStart = reactive({ x: 0, y: 0 })
const pageDragDelta = ref(0)

// Icon dragging
const isDraggingIcon = ref(false)
const isEdgePaging = ref(false)
const dragSourceApp = ref(null)
const dragSourceLocation = reactive({ type: '', page: -1, slot: -1 })
const dragGhostApp = ref(null)
const dragGhostPos = reactive({ x: 0, y: 0 })
const dockHighlightIdx = ref(-1)
let dragStartPageLayouts = null
let dragStartDockIds = null

// Edge drag for cross-page
let edgeTimer = null

const homescreenRef = ref(null)
const viewportRef = ref(null)
const dockRef = ref(null)

// Build app map
const appMap = computed(() => {
  const map = {}
  for (const app of catalogApps.value) {
    map[app.id] = app
  }
  for (const app of availableApps.value) {
    if (!map[app.id]) map[app.id] = app
  }
  return map
})

// Build pages from layout
const pages = computed(() => {
  if (pageLayouts.value.length === 0) return [[]]
  return pageLayouts.value.map(slots =>
    slots.map(id => id ? appMap.value[id] || null : null)
  )
})

const totalPagesWithSearch = computed(() => pages.value.length + 1)
const isSearchPageActive = computed(() => currentPageIndex.value === pages.value.length)
const searchPageProgress = computed(() => {
  const lastAppPageIndex = Math.max(0, pages.value.length - 1)
  return Math.max(
    0,
    Math.min(1, ((-pageOffset.value) - (lastAppPageIndex * PAGE_WIDTH)) / PAGE_WIDTH)
  )
})
const appIdsOnHome = computed(() => {
  const ids = new Set()
  dockIds.value.filter(Boolean).forEach(id => ids.add(id))
  pageLayouts.value.flat().filter(Boolean).forEach(id => ids.add(id))
  return ids
})

const dockSlideOffset = computed(() => {
  const progress = searchPageProgress.value
  return Math.round(-progress * PAGE_WIDTH)
})

// Page offset
const pageOffset = computed(() => {
  const base = -currentPageIndex.value * PAGE_WIDTH
  return base + pageDragDelta.value
})

const baseBackgroundStyle = computed(() => {
  const bgImage = phoneSettings.backgroundImage
  if (bgImage) {
    return {
      backgroundImage: `linear-gradient(180deg, rgba(0, 0, 0, 0.28), rgba(0, 0, 0, 0.1)), url(${bgImage})`,
      backgroundSize: 'cover',
      backgroundPosition: 'center',
      backgroundRepeat: 'no-repeat',
    }
  }

  return {
    background: `linear-gradient(to bottom, #000000, ${phoneSettings.backgroundColor})`,
  }
})

const appsPageStyle = computed(() => {
  if (phoneSettings.backgroundImage) return { background: 'transparent' }
  return {}
})

const listScreenStyle = computed(() => {
  if (phoneSettings.backgroundImage) {
    const screenX = pageOffset.value + pages.value.length * PAGE_WIDTH
    return {
      background: 'transparent',
      '--search-bg-image': `url(${phoneSettings.backgroundImage})`,
      '--search-blur-offset': `${-screenX}px`,
    }
  }

  return {
    background: `linear-gradient(to bottom, #000000, ${phoneSettings.backgroundColor})`,
  }
})

// ─── Layout building ───
function persistLayoutCache() {
  writePhoneLayoutCache({
    pageLayouts: pageLayouts.value,
    dockIds: dockIds.value,
    installedAppIds: installedAppIds.value,
    seenApps: [...seenApps.value],
    removedAppIds: [...removedAppIds.value],
    wallpaper: wallpaper.value,
  })
}

function syncInstalledIds(data) {
  let ids = toIdList(data?.installedAppIds)
  if (!ids.length && data) {
    ids = collectInstalledFromLayout(data)
  }
  if (!ids.length) {
    ids = [...PREINSTALLED_APP_IDS, ...DEFAULT_HOME_APPS.filter(entry => entry.required).map(entry => entry.id)]
  }
  installedAppIds.value = ids
  setInstalledApps(ids)
}

function applyFreshDefaultLayout() {
  dockIds.value = [...DEFAULT_DOCK_IDS]
  pageLayouts.value = buildDefaultLayout()
  installedAppIds.value = defaultInstalledIds()
  setInstalledApps(installedAppIds.value)
  persistLayoutCache()
}

// Lua layout arrays can arrive as numeric-keyed objects.

function applyLayout(data) {
  const pagesSource = toSlotArray(data && data.pages)
  if (data && pagesSource.length > 0) {
    syncInstalledIds(data)
    const installedSet = new Set(installedAppIds.value)

    dockIds.value = toSlotArray(data.dock || DEFAULT_DOCK_IDS)
      .slice(0, 4)
      .map(v => (v && v !== '') ? v : null)
    while (dockIds.value.length < 4) dockIds.value.push(null)

    const dockSet = new Set(dockIds.value.filter(Boolean))
    const seen = new Set(dockSet)
    pageLayouts.value = pagesSource.map(p => {
      const raw = toSlotArray(p && typeof p === 'object' && 'apps' in p ? p.apps : p)
        .slice(0, APPS_PER_PAGE)
        .map(v => (v && v !== '') ? v : null)
      const hasExplicitEmptySlots = raw.some(v => v == null)
      const isCompactList = !hasExplicitEmptySlots && raw.length < APPS_PER_PAGE
      while (raw.length < APPS_PER_PAGE) raw.push(null)
      const slots = new Array(APPS_PER_PAGE).fill(null)
      if (isCompactList) {
        const compactIds = raw.filter(id => id && appMap.value[id] && installedSet.has(id) && !seen.has(id))
        const start = APPS_PER_PAGE - compactIds.length
        compactIds.forEach((id, idx) => {
          seen.add(id)
          slots[start + idx] = id
        })
      } else {
        for (let i = 0; i < APPS_PER_PAGE; i++) {
          const id = raw[i]
          if (!id) continue
          if (!appMap.value[id]) continue
          if (!installedSet.has(id)) continue
          if (seen.has(id)) continue
          seen.add(id)
          slots[i] = id
        }
      }
      return slots
    })

    if (pageLayouts.value.length === 0) {
      pageLayouts.value = buildDefaultLayout()
    }
    seenApps.value = new Set(toIdList(data.seenApps))
    removedAppIds.value = new Set(toIdList(data.removedAppIds))
    wallpaper.value = data.wallpaper || 'default'
    if (data.settings) {
      replacePhoneSettings(data.settings)
    } else if (wallpaper.value !== 'default') {
      replacePhoneSettings({
        ...getPhoneSettingsSnapshot(),
        backgroundImage: wallpaper.value,
      })
    }
  } else {
    applyFreshDefaultLayout()
  }
  persistLayoutCache()
}

function addAppToLastEmpty(appId) {
  if (!installedAppIds.value.includes(appId)) {
    installedAppIds.value = [...installedAppIds.value, appId]
    setInstalledApps(installedAppIds.value)
  }
  removedAppIds.value.delete(appId)
  for (const page of pageLayouts.value) {
    const emptyIdx = page.lastIndexOf(null)
    if (emptyIdx !== -1) {
      page[emptyIdx] = appId
      return
    }
  }
  const newPage = new Array(APPS_PER_PAGE).fill(null)
  newPage[APPS_PER_PAGE - 1] = appId
  pageLayouts.value.push(newPage)
}

function buildSaveData() {
  // Use empty string instead of null for empty slots — null in JS arrays
  // gets lost when serialized through the CEF bridge to Lua
  return {
    version: LAYOUT_VERSION,
    wallpaper: wallpaper.value,
    pages: pageLayouts.value.map(p => ({ apps: p.map(id => id || '') })),
    dock: dockIds.value.map(id => id || ''),
    installedAppIds: [...installedAppIds.value],
    seenApps: [...seenApps.value],
    removedAppIds: [...removedAppIds.value],
    settings: getPhoneSettingsSnapshot(),
  }
}

// Saving before Lua's first response could persist the previous career's layout. Saving before this
// screen knows the apps (discovered list, career state, installed apps: initPhone) could drop every
// icon it cannot resolve yet from the player's layout.
let layoutReceived = false
let phoneReady = false
// Set on unmount: an initPhone still awaiting Lua must not make this destroyed screen ready or replay
// its held layout over the live phone settings, layout cache and installed apps.
let disposed = false

function saveLayout() {
  if (!phoneReady || !layoutReceived || !isPhoneAppCatalogLoaded()) return
  const data = buildSaveData()
  persistLayoutCache()
  try {
    lua.overhaul_phone_apps_layout.updateLayout(data)
  } catch (e) {
    reportUiFailure(e, "Failed to save phone layout (PhoneHomescreen)")
  }
}

function ensureGuideOnHomescreen() {
  if (!installedAppIds.value.includes('guide')) {
    installedAppIds.value = [...installedAppIds.value, 'guide']
    setInstalledApps(installedAppIds.value)
  }
  if (appIdsOnHome.value.has('guide')) return

  if (pageLayouts.value.length === 0) {
    pageLayouts.value = buildDefaultLayout()
    saveLayout()
    return
  }

  const firstPage = pageLayouts.value[0]
  const emptySlot = firstPage.indexOf(null)
  if (emptySlot !== -1) {
    firstPage[emptySlot] = 'guide'
  } else {
    addAppToLastEmpty('guide')
  }
  saveLayout()
}

function ensureEmploymentOnHomescreen() {
  if (removedAppIds.value.has('employment')) return
  if (!installedAppIds.value.includes('employment')) {
    installedAppIds.value = [...installedAppIds.value, 'employment']
    setInstalledApps(installedAppIds.value)
  }
  removedAppIds.value.delete('employment')
  if (appIdsOnHome.value.has('employment')) return

  if (pageLayouts.value.length === 0) {
    pageLayouts.value = buildDefaultLayout()
    saveLayout()
    return
  }

  ensureGuideOnHomescreen()

  const firstPage = pageLayouts.value[0]
  const guideIdx = firstPage.indexOf('guide')
  if (guideIdx !== -1 && guideIdx + 1 < APPS_PER_PAGE && !firstPage[guideIdx + 1]) {
    firstPage[guideIdx + 1] = 'employment'
    saveLayout()
    return
  }

  const emptySlot = firstPage.indexOf(null)
  if (emptySlot !== -1) {
    firstPage[emptySlot] = 'employment'
  } else {
    addAppToLastEmpty('employment')
  }
  saveLayout()
}

async function forceEmploymentInstalled() {
  try {
    await lua.overhaul_phone_apps_layout?.ensureDefaultAppsPlaced?.()
  } catch (error) { reportUiFailure(error, "force employment installed (PhoneHomescreen)") }
  if (disposed) return
  ensureEmploymentOnHomescreen()
}

function ensureVehicleTransferOnHomescreen() {
  if (removedAppIds.value.has('vehicle-transfer')) return
  if (!installedAppIds.value.includes('vehicle-transfer')) {
    installedAppIds.value = [...installedAppIds.value, 'vehicle-transfer']
    setInstalledApps(installedAppIds.value)
  }
  removedAppIds.value.delete('vehicle-transfer')
  if (appIdsOnHome.value.has('vehicle-transfer')) return

  if (pageLayouts.value.length === 0) {
    pageLayouts.value = buildDefaultLayout()
    saveLayout()
    return
  }

  const firstPage = pageLayouts.value[0]
  const employmentIdx = firstPage.indexOf('employment')
  if (employmentIdx !== -1 && employmentIdx + 1 < APPS_PER_PAGE && !firstPage[employmentIdx + 1]) {
    firstPage[employmentIdx + 1] = 'vehicle-transfer'
    saveLayout()
    return
  }

  const emptySlot = firstPage.indexOf(null)
  if (emptySlot !== -1) {
    firstPage[emptySlot] = 'vehicle-transfer'
  } else {
    addAppToLastEmpty('vehicle-transfer')
  }
  saveLayout()
}

watch(phoneStepIndex, idx => {
  if (idx === null) return
  const step = PHONE_TUTORIAL_STEPS[idx]
  if (step?.id === 'guide') {
    ensureGuideOnHomescreen()
    nextTick(() => notifyDockReady())
  }
  if (step?.id === 'employment') {
    forceEmploymentInstalled().then(() => nextTick(() => notifyDockReady()))
  }
  if (step?.id === 'vehicle-transfer') {
    ensureVehicleTransferOnHomescreen()
    nextTick(() => notifyDockReady())
  }
}, { immediate: true })

// ─── Back handler ───
function handleBack() {
  if (movingApp.value) { movingApp.value = null; return true }
  if (jiggleMode.value) {
    exitJiggleMode()
    return true
  }
  if (currentPageIndex.value > 0) {
    goToPage(0)
    return true
  }
  return false
}

// ─── Page navigation ───
const tileMenuApp = ref(null)
const movingApp = ref(null)
function openTileMenu() {
  if (movingApp.value || jiggleMode.value || tutorialBlockLaunches.value) return
  const id = document.activeElement?.closest('[data-app-id]')?.dataset.appId
  const app = appMap.value[id]
  if (app) tileMenuApp.value = app
}
function openMenuApp() { const app = tileMenuApp.value; tileMenuApp.value = null; launchApp(app) }
function startMove() { movingApp.value = tileMenuApp.value; tileMenuApp.value = null; if (isSearchPageActive.value) goToPage(0) }
function placeApp(target) {
  const app = movingApp.value
  if (!app) return
  const layout = placeHomeApp({ pages: pageLayouts.value, dock: dockIds.value, appId: app.id, target, pageSize: APPS_PER_PAGE })
  if (!layout) return
  pageLayouts.value = layout.pages
  dockIds.value = layout.dock
  removedAppIds.value.delete(app.id)
  movingApp.value = null
  if (target.type === 'grid') goToPage(target.page)
  saveLayout()
}
function pinMenuApp() {
  movingApp.value = tileMenuApp.value
  tileMenuApp.value = null
  const empty = dockIds.value.indexOf(null)
  placeApp({ type: 'dock', slot: empty < 0 ? 0 : empty })
}
function removeMenuApp() {
  const app = tileMenuApp.value
  tileMenuApp.value = null
  jiggleMode.value = true
  onRemoveApp(app)
  exitJiggleMode()
}

function goToPage(idx) {
  if (movingApp.value) idx = Math.min(idx, pages.value.length - 1)
  const maxPage = pages.value.length // includes search
  currentPageIndex.value = Math.max(0, Math.min(idx, maxPage))
}

const pageGestures = createPhonePageGestures({ isDraggingIcon, pagePointerStart, pageDragDelta, isDraggingPage, currentPageIndex, pages, PAGE_WIDTH, goToPage, reportUiFailure })
function onViewportPointerDown(e) { return pageGestures.onViewportPointerDown(e) }
function onViewportPointerMove(e) { return pageGestures.onViewportPointerMove(e) }
function onViewportPointerUp(e) { return pageGestures.onViewportPointerUp(e) }

// Pointer capture belongs to this mounted screen.

// ─── Jiggle mode ───
function enterJiggleMode() {
  jiggleMode.value = true
}

function exitJiggleMode() {
  jiggleMode.value = false
  isDraggingIcon.value = false
  dragSourceApp.value = null
  dragGhostApp.value = null
  // Remove empty trailing pages
  while (pageLayouts.value.length > 1 && pageLayouts.value[pageLayouts.value.length - 1].every(id => !id)) {
    pageLayouts.value.pop()
  }
  // Clamp current page if we removed pages
  if (currentPageIndex.value >= pages.value.length) {
    currentPageIndex.value = Math.max(0, pages.value.length - 1)
  }
  saveLayout()
}

// ─── App launch ───
function launchApp(app) {
  if (jiggleMode.value) return
  if (!isLaunchAllowed(app.id)) return
  seenApps.value.add(app.id)
  saveLayout()
  if (app.id === 'guide') {
    advanceAfterGuideTap()
  }
  if (app.id === 'employment') {
    advanceAfterEmploymentTap()
  }
  if (app.id === 'vehicle-transfer') {
    advanceAfterVehicleTransferTap()
  }
  pressedAppId.value = app.id
  phoneScreen?.setOpenIntent({ kind: 'icon', appId: app.id })
  navigatePhoneRoute(router, app.route).then(result => {
    if (result?.success === false) {
      pressedAppId.value = null
      phoneScreen?.clearOpenIntent()
    }
  })
}

function onRemoveApp(app) {
  if (!app || !app.id) return
  if (!jiggleMode.value) return

  const appId = app.id
  if (SYSTEM_APP_IDS.has(appId)) return

  installedAppIds.value = installedAppIds.value.filter(id => id !== appId)
  setInstalledApps(installedAppIds.value)
  removedAppIds.value.add(appId)
  const dockIdx = dockIds.value.indexOf(appId)
  if (dockIdx !== -1) {
    dockIds.value[dockIdx] = null
  }
  while (removeAppFromGrid(appId)) {
    // Remove any duplicate placements defensively.
  }
}

function onSearchDragStart(e, app) {
  if (!jiggleMode.value) return
  startIconDrag(e, app, 'search')
}

// ─── Icon drag ───
function onGridDragStart(e, app) {
  if (!jiggleMode.value) return
  startIconDrag(e, app, 'grid')
}

function onDockDragStart(e, app, source, idx) {
  if (!jiggleMode.value) return
  dragSourceLocation.type = 'dock'
  dragSourceLocation.slot = idx
  startIconDrag(e, app, 'dock')
}

function startIconDrag(e, app, source) {
  isDraggingIcon.value = true
  dragSourceApp.value = app
  dragGhostApp.value = app
  updateDragGhostPosition(e)
  dragStartPageLayouts = pageLayouts.value.map(page => [...page])
  dragStartDockIds = [...dockIds.value]

  if (source === 'search') {
    dragSourceLocation.type = 'search'
    dragSourceLocation.page = -1
    dragSourceLocation.slot = -1
  } else if (source === 'grid') {
    // Find which page/slot this app is in
    for (let p = 0; p < pageLayouts.value.length; p++) {
      const s = pageLayouts.value[p].indexOf(app.id)
      if (s !== -1) {
        dragSourceLocation.type = 'grid'
        dragSourceLocation.page = p
        dragSourceLocation.slot = s
        pageLayouts.value[p][s] = null
        break
      }
    }
  } else if (source === 'dock') {
    dockIds.value[dragSourceLocation.slot] = null
  }

  document.addEventListener('pointermove', onIconDragMove)
  document.addEventListener('pointerup', onIconDragEnd)
}

function onIconDragMove(e) {
  if (!isDraggingIcon.value) return
  updateDragGhostPosition(e)

  const dockEl = dockRef.value?.$el?.querySelector('.phone-dock')
  if (dockEl) {
    const dockRect = dockEl.getBoundingClientRect()
    const overDock = e.clientX >= dockRect.left && e.clientX <= dockRect.right && e.clientY >= dockRect.top && e.clientY <= dockRect.bottom
    if (overDock) {
      const relX = e.clientX - dockRect.left
      const slotWidth = dockRect.width / 4
      const idx = Math.min(3, Math.max(0, Math.floor(relX / slotWidth)))
      dockHighlightIdx.value = idx
    } else {
      dockHighlightIdx.value = -1
      const target = findGridSlotAt(e.clientX, e.clientY)
      if (target) moveDraggedAppToGridSlot(target)
    }
  } else {
    dockHighlightIdx.value = -1
    const target = findGridSlotAt(e.clientX, e.clientY)
    if (target) moveDraggedAppToGridSlot(target)
  }

  const phoneEl2 = viewportRef.value
  if (phoneEl2) {
    const rect = phoneEl2.getBoundingClientRect()
    const relX = e.clientX - rect.left
    if (relX < 30) {
      if (!edgeTimer) {
        edgeTimer = setTimeout(() => {
          if (currentPageIndex.value > 0) {
            isEdgePaging.value = true
            goToPage(currentPageIndex.value - 1)
            setTimeout(() => { isEdgePaging.value = false }, 380)
          }
          edgeTimer = null
        }, 300)
      }
    } else if (relX > rect.width - 30) {
      if (!edgeTimer) {
        edgeTimer = setTimeout(() => {
          const lastAppPage = pages.value.length - 1
          // Don't allow dragging into search page
          if (currentPageIndex.value < lastAppPage) {
            isEdgePaging.value = true
            goToPage(currentPageIndex.value + 1)
            setTimeout(() => { isEdgePaging.value = false }, 380)
          } else if (currentPageIndex.value === lastAppPage) {
            // Create a new page if we're on the last app page
            pageLayouts.value.push(new Array(APPS_PER_PAGE).fill(null))
            isEdgePaging.value = true
            goToPage(currentPageIndex.value + 1)
            setTimeout(() => { isEdgePaging.value = false }, 380)
          }
          edgeTimer = null
        }, 300)
      }
    } else {
      clearTimeout(edgeTimer)
      edgeTimer = null
    }
  }
}

function onIconDragEnd(e) {
  document.removeEventListener('pointermove', onIconDragMove)
  document.removeEventListener('pointerup', onIconDragEnd)
  clearTimeout(edgeTimer)
  edgeTimer = null
  isEdgePaging.value = false

  if (!isDraggingIcon.value || !dragSourceApp.value) return

  const appId = dragSourceApp.value.id

  if (dockHighlightIdx.value >= 0) {
    removedAppIds.value.delete(appId)
    removeAppFromGrid(appId)
    const existingInDock = dockIds.value[dockHighlightIdx.value]
    dockIds.value[dockHighlightIdx.value] = appId
    if (existingInDock) {
      // Displace existing dock app to grid
      addAppToLastEmpty(existingInDock)
    }
  } else {
    const target = findGridSlotAt(e.clientX, e.clientY)
    if (target) {
      moveDraggedAppToGridSlot(target)
    } else {
      const location = findAppLocation(appId)
      if (!location) {
        if (dragSourceLocation.type === 'search') {
          addAppToLastEmpty(appId)
        } else if (dragStartPageLayouts && dragStartDockIds) {
          pageLayouts.value = dragStartPageLayouts.map(page => [...page])
          dockIds.value = [...dragStartDockIds]
        } else if (dragSourceLocation.type === 'grid') {
          pageLayouts.value[dragSourceLocation.page][dragSourceLocation.slot] = appId
        } else if (dragSourceLocation.type === 'dock') {
          dockIds.value[dragSourceLocation.slot] = appId
        }
      }
    }
  }

  isDraggingIcon.value = false
  dragSourceApp.value = null
  dragGhostApp.value = null
  dockHighlightIdx.value = -1
  dragStartPageLayouts = null
  dragStartDockIds = null
  saveLayout()
}

function findGridSlotAt(x, y) {
  const el = document.elementFromPoint(x, y)
  if (!el) return null
  const slotEl = el.closest('.grid-slot')
  if (!slotEl) return null
  const page = parseInt(slotEl.dataset.page)
  const slot = parseInt(slotEl.dataset.slot)
  if (isNaN(page) || isNaN(slot)) return null
  return { page, slot }
}

function updateDragGhostPosition(e) {
  const homeEl = homescreenRef.value
  if (!homeEl) return
  const rect = homeEl.getBoundingClientRect()
  const scaleX = rect.width > 0 ? rect.width / homeEl.offsetWidth : 1
  const scaleY = rect.height > 0 ? rect.height / homeEl.offsetHeight : 1
  dragGhostPos.x = (e.clientX - rect.left) / scaleX - 34
  dragGhostPos.y = (e.clientY - rect.top) / scaleY - 34
}

function findAppLocation(appId) {
  const dockSlot = dockIds.value.indexOf(appId)
  if (dockSlot !== -1) return { type: 'dock', slot: dockSlot }

  for (let p = 0; p < pageLayouts.value.length; p++) {
    const s = pageLayouts.value[p].indexOf(appId)
    if (s !== -1) return { type: 'grid', page: p, slot: s }
  }
  return null
}

function removeAppFromGrid(appId) {
  for (let p = 0; p < pageLayouts.value.length; p++) {
    const s = pageLayouts.value[p].indexOf(appId)
    if (s !== -1) {
      pageLayouts.value[p][s] = null
      return { page: p, slot: s }
    }
  }
  return null
}

function moveDraggedAppToGridSlot(target) {
  if (!dragSourceApp.value) return
  const appId = dragSourceApp.value.id
  removedAppIds.value.delete(appId)
  const current = findAppLocation(appId)

  // If app is in dock while hovering grid, free that dock slot first.
  if (current && current.type === 'dock') {
    dockIds.value[current.slot] = null
  }

  const targetPage = pageLayouts.value[target.page]
  if (!targetPage) return

  // Same page: place directly into slot. Empty slot = move, occupied = swap.
  const currentIdxOnTargetPage = targetPage.indexOf(appId)
  if (currentIdxOnTargetPage !== -1) {
    if (currentIdxOnTargetPage === target.slot) return
    const displaced = targetPage[target.slot]
    targetPage[target.slot] = appId
    targetPage[currentIdxOnTargetPage] = displaced || null
    return
  }

  // Cross-page / dock-to-grid: place into target and relocate displaced app.
  const removedFromOtherPage = removeAppFromGrid(appId)
  const displaced = targetPage[target.slot]
  targetPage[target.slot] = appId

  if (displaced && displaced !== appId) {
    if (removedFromOtherPage) {
      pageLayouts.value[removedFromOtherPage.page][removedFromOtherPage.slot] = displaced
    } else {
      addAppToLastEmpty(displaced)
    }
  }
}

// ─── Keyboard ───


// ─── Lifecycle ───
// After each await: a screen unmounted meanwhile stops (no shared registry, tutorial or layout
// changes from a destroyed screen).
let waitingForCatalog = false
let unsubscribeCatalog = null
let initialization = null

function initPhone() {
  if (!initialization) initialization = refreshPhone().finally(() => { initialization = null })
  return initialization
}

async function refreshPhone() {
  await refreshApps(lua, () => disposed)
  if (disposed) return
  if (!isPhoneAppCatalogLoaded()) {
    // Keep the unresolved layout until background discovery lets this mounted screen recover.
    waitingForCatalog = true
    notifyDockReady()
    return
  }
  waitingForCatalog = false
  setInstalledApps(installedAppIds.value)
  // The owner already migrated and placed defaults in the opening snapshot.
  if (!shellState?.layout) await forceEmploymentInstalled()
  if (disposed) return
  ensureVehicleTransferOnHomescreen()
  notifyDockReady()
  if (!phoneReady) {
    phoneReady = true
    if (pendingLayoutData) onPhoneLayoutData(pendingLayoutData)
  }
}

// Layout data that arrives before this screen knows its apps (initPhone finished: discovered list,
// career state, installed apps) waits for that; applying it earlier would filter out (and the
// follow-up saves would drop) every app the phone cannot resolve yet. The latest one is applied.
let pendingLayoutData = shellState?.layout || null

function onPhoneLayoutData(data) {
  if (disposed) return
  if (!phoneReady) {
    pendingLayoutData = data
    return
  }
  pendingLayoutData = null
  layoutReceived = true
  applyLayout(data)
  ensureEmploymentOnHomescreen()
  ensureVehicleTransferOnHomescreen()
}

function onPhoneShellState(data) {
  if (!data?.layout) return
  setInstalledApps(toIdList(data.layout.installedAppIds), data.careerActive)
  onPhoneLayoutData(data.layout)
}

// Apply the authoritative saved placement during setup, before Vue's first render.
// Discovery can still be running on a UI reload; its pending layout is replayed by initPhone.
if (shellState?.layout && isPhoneAppCatalogLoaded()) {
  applyLayout(shellState.layout)
}

onMounted(async () => {
  events.on('phoneLayoutData', onPhoneLayoutData)
  events.on('phoneShellState', onPhoneShellState)
  unsubscribeCatalog = onPhoneAppsChanged(() => {
    if (disposed || !waitingForCatalog) return
    // Publication during the initial load already has an initPhone waiting for it.
    waitingForCatalog = false
    initPhone()
  })

  try {
    acquireScope(lua, 'phone.layout')
  } catch (e) {
    reportUiFailure(e, "Layout extension load failed (PhoneHomescreen)")
  }

  await initPhone()
  if (disposed) return

  if (!shellState?.layout) {
    try {
      lua.overhaul_phone_apps_layout?.requestLayout?.()
    } catch (e) {
      reportUiFailure(e, "Layout request failed (PhoneHomescreen)")
    }
  }

})

onActivated(() => {
  initPhone()
  if (readPhoneShellState()?.layout) return
  try {
    lua.overhaul_phone_apps_layout?.requestLayout?.()
  } catch (_) { reportUiFailure(_, "optional action (PhoneHomescreen)") }
})

onUnmounted(() => {
  disposeIconVisual?.()
  disposeNavigation()
  disposed = true
  waitingForCatalog = false
  unsubscribeCatalog?.()
  unsubscribeCatalog = null
  phoneReady = false
  pendingLayoutData = null
  events.off('phoneLayoutData', onPhoneLayoutData)
  events.off('phoneShellState', onPhoneShellState)
})
</script>

<style scoped lang="scss">
.tile-menu { position: absolute; inset: auto 18px 130px; z-index: 30; display: grid; gap: 8px; padding: 16px; background: #20232c; border-radius: 16px; }
.tile-menu button { padding: 10px; background: #343846; border: 0; border-radius: 8px; color: white; }

.app-launch-pending { transform: scale(.92); opacity: .65; }
.homescreen {
  position: relative;
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.pages-viewport {
  flex: 1;
  overflow: hidden;
  position: relative;
  padding-top: 0;
  padding-bottom: 16px;
  display: flex;
  align-items: flex-start;
}

.pages-track {
  display: flex;
  height: 100%;
  transition: transform 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94);

  &.no-transition {
    transition: none;
  }
}

.page {
  flex: 0 0 360px;
  width: 360px;
  height: 100%;
  padding: 8px 14px;
  box-sizing: border-box;
}

.apps-page {
  padding-top: 64px;
}

.app-grid {
  display: grid;
  grid-template-columns: repeat(4, 68px);
  grid-template-rows: repeat(4, auto);
  gap: 16px;
  justify-content: center;
  justify-items: center;
}

.grid-slot {
  width: 68px;
  height: 90px;
  display: flex;
  align-items: flex-start;
  justify-content: center;
}

.search-page {
  display: flex;
  flex-direction: column;
  height: 100%;
  border-radius: 24px;
  position: relative;
  overflow: hidden;
  box-shadow:
    inset 0 0 0 1px rgba(var(--bng-add-blue-400-rgb), 0.08);

  &::before {
    content: '';
    position: absolute;
    inset: -20px;
    background-image: var(--search-bg-image, none);
    background-size: cover;
    background-position: center;
    filter: blur(5px) saturate(1.08);
    transform: translateX(var(--search-blur-offset, 0px));
    transition: transform 0.35s cubic-bezier(0.25, 0.46, 0.45, 0.94);
  }

  &.no-transition::before {
    transition: none;
  }

  &::after {
    content: '';
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: linear-gradient(180deg, rgba(var(--bng-ter-blue-gray-900-rgb), 0.28), rgba(var(--bng-ter-blue-gray-900-rgb), 0.18));
    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06);
    pointer-events: none;
  }

  :deep(> *) {
    position: relative;
    z-index: 1;
  }
}

.drag-ghost {
  position: absolute;
  top: 0;
  left: 0;
  z-index: 9999;
  pointer-events: none;
  opacity: 0.9;
  will-change: transform;
}

.done-btn {
  position: absolute;
  top: 8px;
  right: 14px;
  z-index: 30;
  background: rgba(255, 255, 255, 0.2);
  color: white;
  border: 1px solid rgba(255, 255, 255, 0.3);
  border-radius: 14px;
  padding: 4px 14px;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.35);
  }
}
</style>
