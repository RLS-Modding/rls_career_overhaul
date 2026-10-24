<template>
  <div class="phone-app-store" :style="accentStyle">
    <div class="store-browser" :inert="selectedApp ? true : undefined" :aria-hidden="selectedApp ? 'true' : undefined">
      <div class="store-search" data-focus-field>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <circle cx="10.5" cy="10.5" r="7.5" /><path d="m16 16 5 5" />
        </svg>
        <input ref="searchInput" v-model="query" v-bng-text-input bng-nav-item type="text"
          class="store-search-input" placeholder="Search apps" aria-label="Search apps" autocomplete="off" />
        <button v-if="query" type="button" class="store-search-clear" aria-label="Clear search"
          bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired @click="clearSearch">×</button>
      </div>

      <nav class="store-categories" aria-label="App categories" @wheel="scrollCategories">
        <button v-for="category in categories" :key="category" type="button" class="store-chip"
          :aria-pressed="selectedCategory === category" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
          @click="selectedCategory = category">{{ category }}</button>
      </nav>

      <div class="store-list" :aria-busy="loading">
        <template v-if="loading">
          <span class="store-sr-only" role="status">Loading apps</span>
          <div class="store-skeleton-heading" aria-hidden="true"></div>
          <div v-for="index in 6" :key="index" class="store-row store-skeleton" aria-hidden="true">
            <span class="store-row-icon"></span>
            <span class="store-row-copy"><span></span><span></span></span>
            <span class="store-skeleton-pill"></span>
          </div>
        </template>
        <div v-else-if="!filteredApps.length" class="store-empty" role="status">
          <h3>{{ query.trim() ? `No apps match “${query.trim()}”` : 'No apps here yet' }}</h3>
          <p>{{ selectedCategory === 'All' ? 'Try another search or browse the categories.' : `Try another search or category. You’re browsing ${selectedCategory}.` }}</p>
          <button v-if="query" type="button" class="store-empty-action" bng-nav-item
            v-bng-on-ui-nav:ok.asMouse.focusRequired @click="clearSearch">Clear search</button>
          <button v-else-if="selectedCategory !== 'All'" type="button" class="store-empty-action" bng-nav-item
            v-bng-on-ui-nav:ok.asMouse.focusRequired @click="selectedCategory = 'All'">Show all apps</button>
        </div>
        <template v-else>
          <section v-for="section in sections" :key="section.title" class="store-section" :aria-label="section.title">
            <h3 class="store-section-title">{{ section.title }}<span>{{ section.apps.length }}</span></h3>
            <div v-for="app in section.apps" :key="app.id" class="store-row">
              <button type="button" class="store-row-details" :aria-label="`${app.name} details`"
                bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired @click="openAppDetail(app, $event)">
                <span class="store-row-icon" :style="{ backgroundColor: app.iconImage ? 'transparent' : app.color }">
                  <img v-if="app.iconImage" class="store-row-icon-image" :src="app.iconImage" alt="" draggable="false" />
                  <BngIcon v-else :type="app.icon" :style="{ color: app.iconColor }" />
                </span>
                <span class="store-row-copy">
                  <span class="store-row-name">{{ app.name }}</span>
                  <span class="store-row-tagline">{{ rowSubtitle(app) }}</span>
                  <span v-if="app.isUsageUnlocked === false" class="store-row-lock">
                    <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                      <rect x="3" y="7" width="10" height="7" rx="2" /><path d="M5 7V5a3 3 0 0 1 6 0v2" />
                    </svg>Unlock required
                  </span>
                </span>
              </button>
              <PhoneAppStoreAction :app="app" :is-installed="isInstalled(app.id)"
                :is-installing="installingId === app.id" :install-busy="!!installingId" @action="onAppAction(app)" />
            </div>
          </section>
        </template>
      </div>
    </div>

    <PhoneAppStoreDetailSheet
      :app="selectedApp"
      :is-installed="selectedApp ? isInstalled(selectedApp.id) : false"
      :is-installing="selectedApp ? installingId === selectedApp.id : false"
      :install-busy="!!installingId"
      @close="closeAppDetail"
      @install="installApp(selectedApp)"
      @uninstall="uninstallApp(selectedApp)"
      @open="openInstalledApp(selectedApp)"
    />
  </div>
</template>

<script setup>
import { reportUiFailure } from "../../utils/safeLua"

import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon } from '@/common/components/base'
import { vBngTextInput, vBngOnUiNav } from '@/common/directives'
import PhoneAppStoreAction from '../../components/phone/PhoneAppStoreAction.vue'
import { usePhoneScreen } from '../../composables/usePhoneScreen'
import PhoneAppStoreDetailSheet from '../../components/phone/PhoneAppStoreDetailSheet.vue'
import { usePhoneApps } from '../../utils/phoneAppRegistry'
import { navigatePhoneRoute } from '../../utils/phoneNavigation'
import { usePhoneSettings } from '../../composables/usePhoneSettings'
import {
  collectInstalledFromLayout,
  installAppOnLayout,
  isAppInstalled,
  LAYOUT_VERSION,
  uninstallAppFromLayout,
} from '../../utils/phoneLayoutUtils'
import { acquireScope } from '../../utils/luaScopes'

// Installing only saves the home screen layout; the short pause lets the spinner register as feedback.
const INSTALL_DELAY_MS = 300

const router = useRouter()
const events = useEvents()
const { phoneSettings, getPhoneSettingsSnapshot } = usePhoneSettings()
const { refreshCatalogApps, getStoreApps, APPS_PER_PAGE } = usePhoneApps()

const loading = ref(true)
const storeApps = ref([])
const layoutData = ref(null)
const installedIds = ref([])
const installingId = ref(null)
const selectedApp = ref(null)
const query = ref('')
const selectedCategory = ref('All')
const searchInput = ref(null)
let detailTrigger = null

const categories = computed(() => ['All', ...new Set(storeApps.value.map(app => app.category).filter(Boolean))].sort((a, b) => a === 'All' ? -1 : b === 'All' ? 1 : a.localeCompare(b)))
const filteredApps = computed(() => {
  const term = query.value.trim().toLowerCase()
  return storeApps.value.filter(app =>
    (selectedCategory.value === 'All' || app.category === selectedCategory.value) &&
    (!term || [app.name, app.storeTagline, app.category, app.storeDescription]
      .some(value => String(value || '').toLowerCase().includes(term)))
  )
})
const sections = computed(() => {
  if (query.value.trim()) return [{ title: 'Search results', apps: filteredApps.value }]
  return [
    { title: 'On your phone', apps: filteredApps.value.filter(app => isInstalled(app.id)) },
    { title: 'Get more apps', apps: filteredApps.value.filter(app => !isInstalled(app.id)) },
  ].filter(section => section.apps.length)
})

// The chip row hides its scrollbar, so the mouse wheel scrolls it sideways.
function scrollCategories(event) {
  if (!event.deltaY || event.deltaX) return
  event.currentTarget.scrollLeft += event.deltaY
  event.preventDefault()
}

function clearSearch() {
  query.value = ''
  searchInput.value?.focus()
}

function handleBack() {
  if (!selectedApp.value) return false
  closeAppDetail()
  return true
}

function onAppAction(app) {
  if (isInstalled(app.id)) openInstalledApp(app)
  else installApp(app)
}
// Stop pending catalog replies and listener setup when this store has been replaced.
let disposed = false

function hexToRgba(hex, alpha) {
  const normalized = String(hex || '').replace('#', '')
  if (normalized.length !== 6) return `rgba(21, 9, 251, ${alpha})`
  const r = Number.parseInt(normalized.slice(0, 2), 16)
  const g = Number.parseInt(normalized.slice(2, 4), 16)
  const b = Number.parseInt(normalized.slice(4, 6), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

// The selected chip fills with the player's accent, so pick dark text for light accents.
function accentInk(hex) {
  const normalized = String(hex || '').replace('#', '')
  if (normalized.length !== 6) return '#ffffff'
  const [r, g, b] = [0, 2, 4].map(i => Number.parseInt(normalized.slice(i, i + 2), 16))
  return 0.299 * r + 0.587 * g + 0.114 * b > 160 ? '#111114' : '#ffffff'
}

const accentStyle = computed(() => ({
  '--accent-color': phoneSettings.backgroundColor,
  '--accent-faint': hexToRgba(phoneSettings.backgroundColor, 0.12),
  '--accent-border': hexToRgba(phoneSettings.backgroundColor, 0.66),
  '--accent-ink': accentInk(phoneSettings.backgroundColor),
}))

function rowSubtitle(app) {
  return app?.storeTagline || app?.category || ''
}

function syncInstalledFromLayout(data) {
  layoutData.value = data && typeof data === 'object' ? { ...data } : null
  installedIds.value = collectInstalledFromLayout(layoutData.value)
}

function isInstalled(appId) {
  return installedIds.value.includes(appId) || isAppInstalled(layoutData.value, appId)
}

function openAppDetail(app, event) {
  if (!app?.id) return
  detailTrigger = event?.currentTarget || document.activeElement
  selectedApp.value = app
}

function closeAppDetail() {
  selectedApp.value = null
  nextTick(() => {
    if (disposed || selectedApp.value) return
    if (detailTrigger?.isConnected) detailTrigger.focus({ preventScroll: true })
    else searchInput.value?.focus({ preventScroll: true })
  })
}

function openInstalledApp(app) {
  if (!app?.route) return
  navigatePhoneRoute(router, app.route)
}

async function persistLayout(nextLayout) {
  const payload = {
    ...nextLayout,
    version: LAYOUT_VERSION,
    settings: getPhoneSettingsSnapshot(),
  }
  syncInstalledFromLayout(payload)
  await acquireScope(lua, 'phone.layout')
  const ok = await lua.overhaul_phone_apps_layout?.updateLayout?.(payload)
  if (ok === false) throw new Error('Layout save failed')
}

function installApp(app) {
  if (!app?.id || installingId.value || isInstalled(app.id)) return
  installingId.value = app.id
  window.setTimeout(async () => {
    try {
      const base = layoutData.value ? { ...layoutData.value } : {}
      const next = installAppOnLayout(base, app.id, APPS_PER_PAGE)
      await persistLayout(next)
    } catch (err) {
      reportUiFailure(err, "[PhoneAppStore] install failed (PhoneAppStore)")
    } finally {
      installingId.value = null
    }
  }, INSTALL_DELAY_MS)
}

async function uninstallApp(app) {
  if (!app?.id || installingId.value || !isInstalled(app.id)) return
  try {
    const base = layoutData.value ? { ...layoutData.value } : {}
    const next = uninstallAppFromLayout(base, app.id, APPS_PER_PAGE)
    await persistLayout(next)
  } catch (err) {
    reportUiFailure(err, "[PhoneAppStore] uninstall failed (PhoneAppStore)")
  }
}

function onLayoutData(data) {
  syncInstalledFromLayout(data)
}

onMounted(async () => {
  try {
    await refreshCatalogApps(lua, () => disposed)
    if (disposed) return
    storeApps.value = getStoreApps()
    await acquireScope(lua, 'phone.layout')
    if (disposed) return
    events.on('phoneLayoutData', onLayoutData)
    lua.overhaul_phone_apps_layout.requestLayout()
  } catch (err) {
    reportUiFailure(err, "[PhoneAppStore] init failed (PhoneAppStore)")
  } finally {
    if (!disposed) loading.value = false
  }
})

onUnmounted(() => {
  disposed = true
  events.off('phoneLayoutData', onLayoutData)
})
usePhoneScreen({ onBack: handleBack })
</script>

<style scoped>
.phone-app-store {
  position: relative;
  height: 100%;
  background: #0c0c10;
  color: #f8fafc;
  box-sizing: border-box;
}
.store-browser {
  height: 100%;
  display: flex;
  flex-direction: column;
  padding: 52px 16px 16px;
  box-sizing: border-box;
  overflow: hidden;
}
.store-search {
  display: flex;
  align-items: center;
  flex-shrink: 0;
  gap: 9px;
  min-height: 40px;
  padding: 0 12px;
  border-radius: 12px;
  background: #202026;
  color: #a6a6b2;
}
.store-search-input {
  flex: 1;
  min-width: 0;
  width: 100%;
  padding: 10px 0;
  border: 0;
  background: transparent;
  color: #f8fafc;
  font: inherit;
  font-size: 13px;
  outline: none;
}
.store-search-input::placeholder { color: #a6a6b2; }
.store-search-clear { border: 0; border-radius: 50%; background: #393940; color: #f8fafc; width: 24px; height: 24px; padding: 0; font-size: 18px; cursor: pointer; }
.store-categories { display: flex; gap: 6px; flex-shrink: 0; overflow-x: auto; padding: 12px 16px; margin: 0 -16px 4px; scroll-padding-inline: 16px; scrollbar-width: none;
  mask-image: linear-gradient(to right, transparent 0, #000 16px, #000 calc(100% - 28px), transparent 100%); }
.store-categories::-webkit-scrollbar { display: none; }
.store-chip { flex-shrink: 0; border: 0; border-radius: 999px; background: #202026; color: #c6c6d0; padding: 8px 13px; font: inherit; font-size: 11px; font-weight: 600; cursor: pointer; }
.store-chip[aria-pressed="true"] { background: var(--accent-color, #1509fb); color: var(--accent-ink, #ffffff); }
.store-list { flex: 1; min-height: 0; overflow-y: auto; padding: 2px 3px; margin: 0 -3px; scrollbar-width: thin; scrollbar-color: #393940 transparent; }
.store-section + .store-section { margin-top: 20px; }
.store-section-title { display: flex; align-items: baseline; justify-content: space-between; margin: 0 0 6px; font-size: 17px; font-weight: 750; line-height: 1.3; letter-spacing: -0.02em; }
.store-section-title > span { color: #a6a6b2; font-size: 11px; font-weight: 500; letter-spacing: 0; font-variant-numeric: tabular-nums; }
.store-row { display: flex; align-items: center; gap: 8px; min-height: 82px; border-bottom: 1px solid #25252d; }
.store-row-details { display: flex; align-items: center; gap: 10px; flex: 1; min-width: 0; align-self: stretch; padding: 12px 0; border: 0; border-radius: 10px; background: transparent; text-align: left; color: inherit; font: inherit; cursor: pointer; }
.store-row-details:hover { background: #19191f; }
.store-row-icon { display: flex; align-items: center; justify-content: center; flex-shrink: 0; width: 46px; height: 46px; border-radius: 12px; overflow: hidden; font-size: 26px; }
.store-row-icon-image { width: 100%; height: 100%; object-fit: cover; display: block; }
.store-row-copy { display: flex; flex-direction: column; gap: 3px; min-width: 0; flex: 1; }
.store-row-name { font-size: 13px; font-weight: 700; line-height: 1.25; overflow-wrap: anywhere; }
.store-row-tagline { font-size: 11px; line-height: 1.35; color: #a6a6b2; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.store-row-lock { display: flex; align-items: center; gap: 4px; font-size: 11px; line-height: 1.2; color: #e7bc75; }
.store-empty { padding: 36px 12px; text-align: center; overflow-wrap: anywhere; }
.store-empty h3 { font-size: 17px; line-height: 1.3; margin: 0 0 8px; }
.store-empty p { font-size: 12px; line-height: 1.5; color: #a6a6b2; margin: 0 0 16px; }
.store-empty-action { padding: 10px 16px; border: 1px solid #393940; border-radius: 999px; background: #202026; color: #f8fafc; font: inherit; font-size: 12px; cursor: pointer; }
.store-browser button { transition: transform 120ms ease-out; }
.store-browser button:active { transform: scale(0.97); }
/* Scaling a full-width row reads as the list moving, so rows highlight instead. */
.store-browser .store-row-details:active { transform: none; background: #19191f; }
.store-skeleton-heading { width: 120px; height: 22px; background: #202026; border-radius: 6px; margin-bottom: 6px; }
.store-skeleton .store-row-icon, .store-skeleton-pill, .store-skeleton .store-row-copy span { background: #202026; }
.store-skeleton .store-row-copy span { height: 13px; border-radius: 4px; width: 80%; }
.store-skeleton .store-row-copy span + span { width: 60%; height: 11px; }
.store-skeleton-pill { width: 64px; height: 34px; border-radius: 999px; }
.store-sr-only { position: absolute; width: 1px; height: 1px; padding: 0; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
@media (prefers-reduced-motion: reduce) {
  .store-browser button:active { transform: none; opacity: 0.7; }
}
</style>
