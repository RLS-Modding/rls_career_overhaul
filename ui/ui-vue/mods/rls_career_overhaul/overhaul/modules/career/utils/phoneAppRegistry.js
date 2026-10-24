import { ref, shallowReactive } from 'vue'
import {
  DEFAULT_DOCK_APP_IDS,
  DEFAULT_HOME_APPS,
  PREINSTALLED_APP_IDS,
  SYSTEM_APP_IDS,
  toIdList,
} from './phoneLayoutUtils'
import { ensurePhoneApps, getPhoneApps, isPhoneAppCatalogLoaded, onPhoneAppsChanged } from './phoneAppCatalog'
import { acquireScope } from './luaScopes'

// Apps are discovered from manifest files (/gameplay/overhaul/phone/apps/<id>.json, any mod can add
// one); phoneAppCatalog.js loads them. Manifests provide the app metadata.
function isValidManifest(manifest) {
  return !!(manifest && manifest.id && manifest.name && manifest.route && (manifest.icon || manifest.iconImage || manifest.iconTile))
}

function compareAppNames(a, b) {
  return String(a?.name || '').localeCompare(String(b?.name || ''), undefined, { sensitivity: 'base' })
}

function sortAppsByName(apps) {
  return [...(apps || [])].sort(compareAppNames)
}

function loadAppDefinitions() {
  const manifests = getPhoneApps().filter(isValidManifest)

  manifests.sort((a, b) => {
    const pageA = Number.isFinite(a.defaultPage) ? a.defaultPage : 999
    const pageB = Number.isFinite(b.defaultPage) ? b.defaultPage : 999
    if (pageA !== pageB) return pageA - pageB

    const posA = Number.isFinite(a.defaultPosition) ? a.defaultPosition : 999
    const posB = Number.isFinite(b.defaultPosition) ? b.defaultPosition : 999
    if (posA !== posB) return posA - posB

    return compareAppNames(a, b)
  })

  return manifests
}

function normalizeImagePathForBeamNG(path) {
  if (typeof path !== 'string') return path
  if (path.startsWith('/local/ui/ui-vue/')) {
    return path.slice('/local/ui/ui-vue/'.length)
  }
  return path
}

function resolveManifestIconImage(def) {
  const raw = def.iconTile || def.iconImage
  if (typeof raw !== 'string') return raw

  const normalized = normalizeImagePathForBeamNG(raw)
  const hasScheme = /^(?:[a-z]+:)?\/\//i.test(normalized)
  const isDataUri = normalized.startsWith('data:')
  const isAbsoluteLike = normalized.startsWith('/') || normalized.startsWith('./') || normalized.startsWith('../')
  const alreadyTiled = normalized.startsWith('tiles/')

  if (hasScheme || isDataUri || isAbsoluteLike || alreadyTiled) {
    return normalized
  }
  return `/ui/entrypoints/main/rls_career_overhaul/tiles/${normalized}`
}

function enrichApp(def) {
  return {
    ...def,
    iconImage: resolveManifestIconImage(def),
    systemApp: def.systemApp === true || SYSTEM_APP_IDS.has(def.id),
    hideFromStore: def.hideFromStore === true || SYSTEM_APP_IDS.has(def.id),
  }
}

const phoneImages = new Map()

// Decode the small visible icon set and saved wallpaper while the closed phone receives its layout.
// Keeping Image objects avoids repeating decoding on every home-screen mount; there are no timers.
export function preloadPhoneImages(layout) {
  if (typeof Image === 'undefined') return
  const ids = new Set(layout ? toIdList(layout.installedAppIds) : [
    ...PREINSTALLED_APP_IDS, ...DEFAULT_HOME_APPS.map(entry => entry.id),
  ])
  const paths = getPhoneApps().filter(app => ids.has(app.id)).map(resolveManifestIconImage)
  paths.push(layout?.settings?.backgroundImage)
  const wanted = new Set(paths.filter(Boolean))
  for (const path of phoneImages.keys()) {
    if (!wanted.has(path)) phoneImages.delete(path)
  }
  for (const path of paths) {
    if (!path || phoneImages.has(path)) continue
    const image = new Image()
    phoneImages.set(path, image)
    image.src = path
    image.decode?.().catch(() => {})
  }
}

export function clearPhoneImages() {
  phoneImages.clear()
}

// Stable arrays, updated in place when the discovered app list (re)loads: every consumer, even one
// created before discovery, sees the current apps (shallowReactive: the entries stay plain objects).
const APP_DEFINITIONS = shallowReactive([])

const APPS_PER_PAGE = 16
const GRID_COLS = 4
const GRID_ROWS = 4

// The default dock has one source, the catalog (declared order, then id; the same rule as Lua).
function buildDefaultDockIds() {
  return [0, 1, 2, 3].map(idx => DEFAULT_DOCK_APP_IDS[idx] || null)
}

const DEFAULT_DOCK_IDS = shallowReactive(buildDefaultDockIds())

onPhoneAppsChanged(() => {
  APP_DEFINITIONS.splice(0, APP_DEFINITIONS.length, ...loadAppDefinitions().map(enrichApp))
  DEFAULT_DOCK_IDS.splice(0, DEFAULT_DOCK_IDS.length, ...buildDefaultDockIds())
  preloadPhoneImages()
})

const catalogApps = ref([])
const availableApps = ref([])
let catalogCareerActive = false

export const DEFAULT_SKILL_LOCKED_MESSAGE = 'Unlock skill to use this app'

// What a locked app tells the player: its manifest's lockedMessage (which names the skill), else the default.
// Reads the reactive definitions, so a computed around it updates once the catalog loads; an app opened
// before the phone home screen starts that load itself.
export function getAppLockedMessage(appId) {
  if (!isPhoneAppCatalogLoaded()) ensurePhoneApps().catch(() => {})
  const message = APP_DEFINITIONS.find(app => app.id === appId)?.lockedMessage
  return typeof message === 'string' && message ? message : DEFAULT_SKILL_LOCKED_MESSAGE
}

async function isCareerActive(luaBridge) {
  try {
    await acquireScope(luaBridge, 'phone.layout')
    const fromLayout = await luaBridge.overhaul_phone_apps_layout.getCareerActive()
    if (typeof fromLayout === 'boolean') return fromLayout
  } catch { /* layout optional */ }
  try {
    return !!(await luaBridge.overhaul_career_career.isActive())
  } catch {
    return false
  }
}

async function passesUnlock(def, luaBridge) {
  if (!def.unlockCondition) return true
  try {
    return !!(await def.unlockCondition(luaBridge))
  } catch (err) {
    console.warn(`[phoneAppRegistry] unlockCondition failed for '${def.id}'`, err)
    return false
  }
}

function catalogEntry(def, isUsageUnlocked) {
  const enriched = enrichApp(def)
  const storeTagline = typeof def.storeTagline === 'string' && def.storeTagline.trim()
    ? def.storeTagline.trim()
    : (def.category || '')
  const storeDescription = typeof def.storeDescription === 'string' && def.storeDescription.trim()
    ? def.storeDescription.trim()
    : `Install ${def.name} on your home screen for quick access during your career.`
  return {
    ...enriched,
    storeTagline,
    storeDescription,
    isUsageUnlocked,
    lockedMessage: typeof def.lockedMessage === 'string' && def.lockedMessage
      ? def.lockedMessage
      : DEFAULT_SKILL_LOCKED_MESSAGE,
  }
}

export function usePhoneApps() {
  // Catalog refs are shared by Home and App Store. A disposed consumer must not publish its
  // pending Lua replies over the live consumer's catalog or installed-app filtering.
  async function refreshApps(luaBridge, isDisposed = () => false) {
    if (isDisposed()) return
    if (!isPhoneAppCatalogLoaded()) {
      await ensurePhoneApps()
      if (isDisposed()) return
    }
    const catalog = []
    const careerActive = await isCareerActive(luaBridge)
    if (isDisposed()) return
    catalogCareerActive = careerActive
    // Independent gates must not turn the app count into serial bridge latency.
    const entries = await Promise.all(APP_DEFINITIONS.map(async def => {
      if (def.careerOnly && !careerActive) return null
      if (!def.unlockCondition) {
        return catalogEntry(def, true)
      }
      const unlocked = await passesUnlock(def, luaBridge)
      if (isDisposed()) return null
      if (unlocked) {
        return catalogEntry(def, true)
      }
      // Skill-gated apps: visible in the store during career even before the skill unlocks.
      if (def.showInStoreWhenLocked && careerActive) {
        return catalogEntry(def, false)
      }
      return null
    }))
    if (isDisposed()) return
    catalog.push(...entries.filter(Boolean))
    catalogApps.value = sortAppsByName(catalog)
    if (isDisposed()) return
    availableApps.value = catalogApps.value
  }

  async function refreshCatalogApps(luaBridge, isDisposed = () => false) {
    await refreshApps(luaBridge, isDisposed)
    if (isDisposed()) return
    return catalogApps.value
  }

  function setInstalledApps(installedIds, careerActive = catalogCareerActive) {
    catalogCareerActive = careerActive
    const installed = new Set(installedIds || [])
    PREINSTALLED_APP_IDS.forEach(id => installed.add(id))
    const catalogById = new Map(catalogApps.value.map(app => [app.id, app]))
    const out = []
    for (const id of installed) {
      if (catalogById.has(id)) {
        out.push(catalogById.get(id))
        continue
      }
      const def = APP_DEFINITIONS.find(app => app.id === id)
      if (def && (!def.careerOnly || catalogCareerActive)) out.push(catalogEntry(def, false))
    }
    availableApps.value = sortAppsByName(out)
  }

  async function isAppUsageUnlocked(appId, luaBridge) {
    if (!isPhoneAppCatalogLoaded()) await ensurePhoneApps()
    const def = APP_DEFINITIONS.find(app => app.id === appId)
    if (!def) return true
    if (def.careerOnly && !(await isCareerActive(luaBridge))) return false
    return passesUnlock(def, luaBridge)
  }

  function getStoreApps() {
    return sortAppsByName(catalogApps.value.filter(app => !app.hideFromStore))
  }

  return {
    availableApps,
    catalogApps,
    refreshApps,
    refreshCatalogApps,
    setInstalledApps,
    getStoreApps,
    isAppUsageUnlocked,
    APP_DEFINITIONS,
    DEFAULT_SKILL_LOCKED_MESSAGE,
    APPS_PER_PAGE,
    GRID_COLS,
    GRID_ROWS,
    DEFAULT_DOCK_IDS,
    PREINSTALLED_APP_IDS,
    SYSTEM_APP_IDS,
  }
}
