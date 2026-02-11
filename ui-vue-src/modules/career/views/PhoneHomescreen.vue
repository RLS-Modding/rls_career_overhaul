<template>
  <PhoneWrapper app-name="Home" :custom-back="handleBack">
    <div ref="homescreenRef" class="homescreen" :style="wallpaperStyle">
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
            class="page apps-page"
          >
            <div class="app-grid">
              <div
                v-for="(app, slotIdx) in page"
                :key="app ? app.id : 'empty-' + pageIdx + '-' + slotIdx"
                class="grid-slot"
                :data-page="pageIdx"
                :data-slot="slotIdx"
              >
                <PhoneAppIcon
                  v-if="app && !(isDraggingIcon && dragSourceApp?.id === app.id)"
                  :app="app"
                  :jiggle-mode="jiggleMode"
                  :jiggle-offset="(pageIdx * 20 + slotIdx) % 7"
                  :is-new="!seenApps.has(app.id)"
                  @launch="launchApp"
                  @longpress="enterJiggleMode"
                  @dragstart="onGridDragStart"
                  @remove="onRemoveApp"
                />
              </div>
            </div>
          </div>

          <!-- Search page -->
          <div class="page search-page">
            <PhoneSearch
              :apps="availableApps"
              :seen-apps="seenApps"
              @launch="launchApp"
            />
          </div>
        </div>
      </div>

      <!-- Dock (with integrated page dots) -->
      <PhoneDock
        ref="dockRef"
        :class="{ 'no-transition': isDraggingPage || (isDraggingIcon && !isEdgePaging) }"
        :style="dockStyle"
        :dock-ids="dockIds"
        :app-map="appMap"
        :jiggle-mode="jiggleMode"
        :highlight-index="dockHighlightIdx"
        :total-pages="pages.length"
        :current-page="currentPageIndex"
        :is-search-active="isSearchPageActive"
        @launch="launchApp"
        @longpress="enterJiggleMode"
        @dragstart="onDockDragStart"
        @go-page="goToPage"
        @remove="onRemoveApp"
      />

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
  </PhoneWrapper>
</template>

<script setup>
import { ref, computed, onMounted, onActivated, onUnmounted, reactive } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import PhoneWrapper from './PhoneWrapper.vue'
import PhoneAppIcon from '../components/phone/PhoneAppIcon.vue'
import PhoneDock from '../components/phone/PhoneDock.vue'
import PhoneSearch from '../components/phone/PhoneSearch.vue'
import { usePhoneApps } from '../utils/phoneAppRegistry'

const PAGE_WIDTH = 360

const router = useRouter()
const events = useEvents()
const { availableApps, refreshApps, DEFAULT_DOCK_IDS, APPS_PER_PAGE } = usePhoneApps()

// Layout state
const dockIds = ref([...DEFAULT_DOCK_IDS])
const pageLayouts = ref([])
const seenApps = ref(new Set())
const wallpaper = ref('default')
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
  for (const app of availableApps.value) {
    map[app.id] = app
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
const dockStyle = computed(() => {
  const progress = searchPageProgress.value
  const slideX = Math.round(-progress * PAGE_WIDTH)
  return {
    transform: `translateX(${slideX}px)`,
    opacity: '1',
    pointerEvents: 'auto',
  }
})

// Page offset
const pageOffset = computed(() => {
  const base = -currentPageIndex.value * PAGE_WIDTH
  return base + pageDragDelta.value
})

const wallpaperStyle = computed(() => {
  if (wallpaper.value === 'default') {
    return { background: 'linear-gradient(to bottom, #000000, #1509fb)' }
  }
  return { backgroundImage: `url(${wallpaper.value})`, backgroundSize: 'cover', backgroundPosition: 'center' }
})

// ─── Layout building ───
function buildDefaultLayout() {
  const gridApps = availableApps.value.filter(a => !dockIds.value.includes(a.id))
  const pagesArr = []
  for (let i = 0; i < gridApps.length; i += APPS_PER_PAGE) {
    const pageSlots = new Array(APPS_PER_PAGE).fill(null)
    const chunk = gridApps.slice(i, i + APPS_PER_PAGE)
    const startIdx = APPS_PER_PAGE - chunk.length
    for (let j = 0; j < chunk.length; j++) {
      pageSlots[startIdx + j] = chunk[j].id
    }
    pagesArr.push(pageSlots)
  }
  if (pagesArr.length === 0) pagesArr.push(new Array(APPS_PER_PAGE).fill(null))
  return pagesArr
}

function toSlotArray(value) {
  if (Array.isArray(value)) return [...value]
  if (value && typeof value === 'object') {
    const numericKeys = Object.keys(value)
      .filter(k => /^\d+$/.test(k))
      .sort((a, b) => Number(a) - Number(b))
    if (numericKeys.length > 0) return numericKeys.map(k => value[k])
    return Object.values(value)
  }
  return []
}

function applyLayout(data) {
  const pagesSource = toSlotArray(data && data.pages)
  if (data && pagesSource.length > 0) {
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
        const compactIds = raw.filter(id => id && appMap.value[id] && !seen.has(id))
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
          if (seen.has(id)) continue
          seen.add(id)
          slots[i] = id
        }
      }
      return slots
    })

    if (pageLayouts.value.length === 0) {
      pageLayouts.value = [new Array(APPS_PER_PAGE).fill(null)]
    }
    seenApps.value = new Set(data.seenApps || [])
    wallpaper.value = data.wallpaper || 'default'

    // Add any new apps not in layout
    const allLayoutIds = new Set([
      ...dockIds.value.filter(Boolean),
      ...pageLayouts.value.flat().filter(Boolean),
    ])
    for (const app of availableApps.value) {
      if (!allLayoutIds.has(app.id)) {
        addAppToLastEmpty(app.id)
      }
    }
  } else {
    pageLayouts.value = buildDefaultLayout()
  }
}

function addAppToLastEmpty(appId) {
  for (const page of pageLayouts.value) {
    const emptyIdx = page.lastIndexOf(null)
    if (emptyIdx !== -1) {
      page[emptyIdx] = appId
      return
    }
  }
  // All full, add new page
  const newPage = new Array(APPS_PER_PAGE).fill(null)
  newPage[APPS_PER_PAGE - 1] = appId
  pageLayouts.value.push(newPage)
}

function buildSaveData() {
  // Use empty string instead of null for empty slots — null in JS arrays
  // gets lost when serialized through the CEF bridge to Lua
  return {
    version: 1,
    wallpaper: wallpaper.value,
    pages: pageLayouts.value.map(p => ({ apps: p.map(id => id || '') })),
    dock: dockIds.value.map(id => id || ''),
    seenApps: [...seenApps.value],
  }
}

function saveLayout() {
  const data = buildSaveData()
  try {
    lua.ui_phone_layout.updateLayout(data)
  } catch (e) {
    console.warn('Failed to save phone layout', e)
  }
}

// ─── Back handler ───
function handleBack() {
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
function goToPage(idx) {
  const maxPage = pages.value.length // includes search
  currentPageIndex.value = Math.max(0, Math.min(idx, maxPage))
}

let isPointerDown = false

function onViewportPointerDown(e) {
  if (isDraggingIcon.value) return
  isPointerDown = true
  pagePointerStart.x = e.clientX
  pagePointerStart.y = e.clientY
  pageDragDelta.value = 0
  isDraggingPage.value = false
  // Capture pointer so we get events even if cursor leaves the phone
  if (e.target && e.target.setPointerCapture) {
    try { e.target.setPointerCapture(e.pointerId) } catch (_) {}
  }
}

function onViewportPointerMove(e) {
  if (!isPointerDown || isDraggingIcon.value) return
  const dx = e.clientX - pagePointerStart.x
  if (!isDraggingPage.value && Math.abs(dx) > 8) {
    isDraggingPage.value = true
  }
  if (isDraggingPage.value) {
    // Block dragging right when on search page (rightmost)
    const onSearchPage = currentPageIndex.value === pages.value.length
    if (onSearchPage && dx < 0) {
      pageDragDelta.value = 0
    } else {
      // Clamp to one page width max so you can't visually skip pages
      pageDragDelta.value = Math.max(-PAGE_WIDTH, Math.min(PAGE_WIDTH, dx))
    }
  }
}

function onViewportPointerUp(e) {
  if (!isPointerDown) return
  isPointerDown = false
  // Release pointer capture
  if (e && e.target && e.target.releasePointerCapture) {
    try { e.target.releasePointerCapture(e.pointerId) } catch (_) {}
  }
  if (isDraggingPage.value) {
    const threshold = 40
    const onSearchPage = currentPageIndex.value === pages.value.length
    if (pageDragDelta.value < -threshold && !onSearchPage) {
      goToPage(currentPageIndex.value + 1)
    } else if (pageDragDelta.value > threshold) {
      goToPage(currentPageIndex.value - 1)
    }
  }
  isDraggingPage.value = false
  pageDragDelta.value = 0
}

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
  seenApps.value.add(app.id)
  saveLayout()
  router.push(app.route)
}

function onRemoveApp(app) {
  if (!app || !app.id) return
  if (!jiggleMode.value) return

  const appId = app.id
  const dockIdx = dockIds.value.indexOf(appId)
  if (dockIdx !== -1) {
    dockIds.value[dockIdx] = null
  }
  while (removeAppFromGrid(appId)) {
    // Remove any duplicate placements defensively.
  }
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

  if (source === 'grid') {
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
    // Drop into dock
    removeAppFromGrid(appId)
    const existingInDock = dockIds.value[dockHighlightIdx.value]
    dockIds.value[dockHighlightIdx.value] = appId
    if (existingInDock) {
      // Displace existing dock app to grid
      addAppToLastEmpty(existingInDock)
    }
  } else {
    // Drop into grid - find slot under cursor
    const target = findGridSlotAt(e.clientX, e.clientY)
    if (target) {
      moveDraggedAppToGridSlot(target)
    } else {
      // If app already has a valid placement from live drag, keep it.
      const location = findAppLocation(appId)
      if (!location) {
        // Invalid drop with no current placement: restore exact pre-drag layout.
        if (dragStartPageLayouts && dragStartDockIds) {
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
function onKeyDown(e) {
  if (e.key === 'ArrowLeft') goToPage(currentPageIndex.value - 1)
  else if (e.key === 'ArrowRight') goToPage(currentPageIndex.value + 1)
  else if (e.key === 'Escape' && jiggleMode.value) exitJiggleMode()
}

// ─── Lifecycle ───
async function initPhone() {
  await refreshApps(lua)
}

onMounted(async () => {
  await initPhone()

  // Load layout from Lua
  try {
    lua.extensions.load('ui_phone_layout')
    events.on('phoneLayoutData', (data) => {
      applyLayout(data)
    })
    lua.ui_phone_layout.requestLayout()
  } catch (e) {
    console.warn('Layout load failed, using defaults', e)
    applyLayout(null)
  }

  // Fallback: if no layout event in 500ms, use defaults
  setTimeout(() => {
    if (pageLayouts.value.length === 0) {
      applyLayout(null)
    }
  }, 500)

  document.addEventListener('keydown', onKeyDown)
})

onActivated(() => {
  initPhone()
})

onUnmounted(() => {
  document.removeEventListener('keydown', onKeyDown)
})
</script>

<style scoped lang="scss">
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
  height: auto;
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
  backdrop-filter: blur(10px);
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
