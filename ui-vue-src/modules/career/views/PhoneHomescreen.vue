<template>
  <PhoneWrapper app-name="Home" status-font-color="#FFFFFF" status-blend-mode="">
    <div class="homescreen" :style="wallpaperStyle">
      <!-- Pages container -->
      <div
        class="pages-viewport"
        @pointerdown="onViewportPointerDown"
        @pointermove="onViewportPointerMove"
        @pointerup="onViewportPointerUp"
      >
        <div
          class="pages-track"
          :class="{ 'no-transition': isDraggingPage || isDraggingIcon }"
          :style="{ transform: `translateX(${pageOffset}px)` }"
        >
          <!-- App pages -->
          <div
            v-for="(page, pageIdx) in pages"
            :key="'page-' + pageIdx"
            class="page"
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
                  :is-launching="launchingAppId === app.id"
                  @launch="launchApp"
                  @longpress="enterJiggleMode"
                  @dragstart="onGridDragStart"
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

      <!-- Page dots -->
      <PhonePageDots
        :total-pages="pages.length"
        :current-page="currentPageIndex"
        :is-search-active="currentPageIndex === pages.length"
        @go="goToPage"
      />

      <!-- Dock -->
      <PhoneDock
        :dock-ids="dockIds"
        :app-map="appMap"
        :jiggle-mode="jiggleMode"
        :highlight-index="dockHighlightIdx"
        @launch="launchApp"
        @longpress="enterJiggleMode"
        @dragstart="onDockDragStart"
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
import { ref, computed, onMounted, onUnmounted, watch, reactive, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import PhoneWrapper from './PhoneWrapper.vue'
import PhoneAppIcon from '../components/phone/PhoneAppIcon.vue'
import PhoneDock from '../components/phone/PhoneDock.vue'
import PhonePageDots from '../components/phone/PhonePageDots.vue'
import PhoneSearch from '../components/phone/PhoneSearch.vue'
import { usePhoneApps } from '../utils/phoneAppRegistry'

const APPS_PER_PAGE = 20
const PAGE_WIDTH = 360

const router = useRouter()
const events = useEvents()
const { availableApps, refreshApps, DEFAULT_DOCK_IDS } = usePhoneApps()

// Layout state
const dockIds = ref([...DEFAULT_DOCK_IDS])
const pageLayouts = ref([]) // array of arrays of app IDs (with nulls for empty slots)
const seenApps = ref(new Set())
const wallpaper = ref('default')
const currentPageIndex = ref(0)
const launchingAppId = ref(null)

// Jiggle mode
const jiggleMode = ref(false)

// Page dragging
const isDraggingPage = ref(false)
const pagePointerStart = reactive({ x: 0, y: 0 })
const pageDragDelta = ref(0)

// Icon dragging
const isDraggingIcon = ref(false)
const dragSourceApp = ref(null)
const dragSourceLocation = reactive({ type: '', page: -1, slot: -1 })
const dragGhostApp = ref(null)
const dragGhostPos = reactive({ x: 0, y: 0 })
const dockHighlightIdx = ref(-1)

// Edge drag for cross-page
let edgeTimer = null

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
    const pageSlots = []
    const chunk = gridApps.slice(i, i + APPS_PER_PAGE)
    for (let j = 0; j < APPS_PER_PAGE; j++) {
      pageSlots.push(chunk[j] ? chunk[j].id : null)
    }
    pagesArr.push(pageSlots)
  }
  if (pagesArr.length === 0) pagesArr.push(new Array(APPS_PER_PAGE).fill(null))
  return pagesArr
}

function applyLayout(data) {
  if (data && data.pages && data.pages.length > 0) {
    dockIds.value = data.dock || [...DEFAULT_DOCK_IDS]
    pageLayouts.value = data.pages.map(p => {
      const slots = [...(p.apps || p)]
      while (slots.length < APPS_PER_PAGE) slots.push(null)
      return slots
    })
    seenApps.value = new Set(data.seenApps || [])
    wallpaper.value = data.wallpaper || 'default'

    // Add any new apps not in layout
    const allLayoutIds = new Set([
      ...dockIds.value.filter(Boolean),
      ...pageLayouts.value.flat().filter(Boolean),
    ])
    for (const app of availableApps.value) {
      if (!allLayoutIds.has(app.id)) {
        addAppToFirstEmpty(app.id)
      }
    }
  } else {
    pageLayouts.value = buildDefaultLayout()
  }
}

function addAppToFirstEmpty(appId) {
  for (const page of pageLayouts.value) {
    const emptyIdx = page.indexOf(null)
    if (emptyIdx !== -1) {
      page[emptyIdx] = appId
      return
    }
  }
  // All full, add new page
  const newPage = new Array(APPS_PER_PAGE).fill(null)
  newPage[0] = appId
  pageLayouts.value.push(newPage)
}

function buildSaveData() {
  return {
    version: 1,
    wallpaper: wallpaper.value,
    pages: pageLayouts.value.map(p => ({ apps: [...p] })),
    dock: [...dockIds.value],
    seenApps: [...seenApps.value],
  }
}

function saveLayout() {
  try {
    lua.ui_phone_layout.updateLayout(buildSaveData())
  } catch (e) {
    console.warn('Failed to save phone layout', e)
  }
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
}

function onViewportPointerMove(e) {
  if (!isPointerDown || isDraggingIcon.value) return
  const dx = e.clientX - pagePointerStart.x
  if (!isDraggingPage.value && Math.abs(dx) > 8) {
    isDraggingPage.value = true
  }
  if (isDraggingPage.value) {
    pageDragDelta.value = dx
  }
}

function onViewportPointerUp() {
  if (!isPointerDown) return
  isPointerDown = false
  if (isDraggingPage.value) {
    const threshold = 40
    if (pageDragDelta.value < -threshold) {
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
  saveLayout()
}

// ─── App launch ───
function launchApp(app) {
  if (jiggleMode.value) return
  // Mark as seen
  seenApps.value.add(app.id)
  launchingAppId.value = app.id
  saveLayout()
  setTimeout(() => {
    launchingAppId.value = null
    router.push(app.route)
  }, 250)
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
  dragGhostPos.x = e.clientX - 34
  dragGhostPos.y = e.clientY - 34

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
  dragGhostPos.x = e.clientX - 34
  dragGhostPos.y = e.clientY - 34

  // Check dock zone (bottom ~88px of phone screen)
  const phoneEl = document.querySelector('.homescreen')
  if (phoneEl) {
    const rect = phoneEl.getBoundingClientRect()
    const relY = e.clientY - rect.top
    if (relY > rect.height - 88) {
      // Over dock
      const relX = e.clientX - rect.left
      const slotWidth = rect.width / 4
      const idx = Math.min(3, Math.max(0, Math.floor(relX / slotWidth)))
      dockHighlightIdx.value = idx
    } else {
      dockHighlightIdx.value = -1
    }
  }

  // Edge detection for cross-page drag
  const phoneEl2 = document.querySelector('.pages-viewport')
  if (phoneEl2) {
    const rect = phoneEl2.getBoundingClientRect()
    const relX = e.clientX - rect.left
    if (relX < 30) {
      if (!edgeTimer) {
        edgeTimer = setTimeout(() => {
          goToPage(currentPageIndex.value - 1)
          edgeTimer = null
        }, 300)
      }
    } else if (relX > rect.width - 30) {
      if (!edgeTimer) {
        edgeTimer = setTimeout(() => {
          goToPage(currentPageIndex.value + 1)
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

  if (!isDraggingIcon.value || !dragSourceApp.value) return

  const appId = dragSourceApp.value.id

  if (dockHighlightIdx.value >= 0) {
    // Drop into dock
    const existingInDock = dockIds.value[dockHighlightIdx.value]
    dockIds.value[dockHighlightIdx.value] = appId
    if (existingInDock) {
      // Displace existing dock app to grid
      addAppToFirstEmpty(existingInDock)
    }
  } else {
    // Drop into grid - find slot under cursor
    const target = findGridSlotAt(e.clientX, e.clientY)
    if (target) {
      const existing = pageLayouts.value[target.page][target.slot]
      pageLayouts.value[target.page][target.slot] = appId
      if (existing) {
        // Swap: put displaced app in original location
        if (dragSourceLocation.type === 'grid') {
          pageLayouts.value[dragSourceLocation.page][dragSourceLocation.slot] = existing
        } else {
          addAppToFirstEmpty(existing)
        }
      }
    } else {
      // Return to original position
      if (dragSourceLocation.type === 'grid') {
        pageLayouts.value[dragSourceLocation.page][dragSourceLocation.slot] = appId
      } else if (dragSourceLocation.type === 'dock') {
        dockIds.value[dragSourceLocation.slot] = appId
      }
    }
  }

  isDraggingIcon.value = false
  dragSourceApp.value = null
  dragGhostApp.value = null
  dockHighlightIdx.value = -1
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

// ─── Keyboard ───
function onKeyDown(e) {
  if (e.key === 'ArrowLeft') goToPage(currentPageIndex.value - 1)
  else if (e.key === 'ArrowRight') goToPage(currentPageIndex.value + 1)
  else if (e.key === 'Escape' && jiggleMode.value) exitJiggleMode()
}

// ─── Lifecycle ───
onMounted(async () => {
  await refreshApps(lua)

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

onUnmounted(() => {
  document.removeEventListener('keydown', onKeyDown)
  if (jiggleMode.value) saveLayout()
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
  padding-top: 50px;
  padding-bottom: 100px;
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

.app-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  grid-template-rows: repeat(5, auto);
  gap: 14px 10px;
  justify-items: center;
  align-content: end;
  height: 100%;
}

.grid-slot {
  width: 78px;
  height: 90px;
  display: flex;
  align-items: flex-start;
  justify-content: center;
}

.search-page {
  display: flex;
  flex-direction: column;
}

.drag-ghost {
  position: fixed;
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
