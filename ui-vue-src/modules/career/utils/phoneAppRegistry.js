import { ref } from 'vue'
// Add a new app by creating `ui-vue-src/modules/career/apps/manifests/<app-id>.js`
// and exporting a default manifest object.
const manifestModules = import.meta.glob('../apps/manifests/*.js', { eager: true })

function isValidManifest(manifest) {
  return !!(manifest && manifest.id && manifest.name && manifest.route && (manifest.icon || manifest.iconImage || manifest.iconTile))
}

function loadAppDefinitions() {
  const manifests = Object.values(manifestModules)
    .map(mod => mod.default || mod.manifest)
    .filter(isValidManifest)

  manifests.sort((a, b) => {
    const pageA = Number.isFinite(a.defaultPage) ? a.defaultPage : 999
    const pageB = Number.isFinite(b.defaultPage) ? b.defaultPage : 999
    if (pageA !== pageB) return pageA - pageB

    const posA = Number.isFinite(a.defaultPosition) ? a.defaultPosition : 999
    const posB = Number.isFinite(b.defaultPosition) ? b.defaultPosition : 999
    if (posA !== posB) return posA - posB

    return String(a.name).localeCompare(String(b.name))
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
  // Standard phone tile location in this project.
  return `/ui/entrypoints/main/tiles/${normalized}`
}

const APP_DEFINITIONS = loadAppDefinitions()

const APPS_PER_PAGE = 16
const GRID_COLS = 4
const GRID_ROWS = 4
const DEFAULT_DOCK_IDS = (() => {
  const dock = new Array(4).fill(null)
  for (const app of APP_DEFINITIONS) {
    if (!Number.isInteger(app.defaultDock)) continue
    if (app.defaultDock < 0 || app.defaultDock >= 4) continue
    if (!dock[app.defaultDock]) dock[app.defaultDock] = app.id
  }
  return dock.map((id, idx) => id || ['guide', 'beam-eats', 'taxi', 'bank'][idx]).filter(Boolean)
})()

export function usePhoneApps() {
  const availableApps = ref([])

  async function refreshApps(luaBridge) {
    const apps = []
    for (const def of APP_DEFINITIONS) {
      if (def.unlockCondition) {
        const unlocked = await def.unlockCondition(luaBridge)
        if (!unlocked) continue
      }
      apps.push({
        ...def,
        iconImage: resolveManifestIconImage(def),
      })
    }
    availableApps.value = apps
  }

  return { availableApps, refreshApps, APP_DEFINITIONS, APPS_PER_PAGE, GRID_COLS, GRID_ROWS, DEFAULT_DOCK_IDS }
}
