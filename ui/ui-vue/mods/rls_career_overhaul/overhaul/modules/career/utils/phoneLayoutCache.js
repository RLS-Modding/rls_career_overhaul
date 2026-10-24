const CACHE_KEY = 'phone_layout_snapshot'

/** @type {PhoneLayoutCacheSnapshot | null} */
let memorySnapshot = null

/**
 * @typedef {Object} PhoneLayoutCacheSnapshot
 * @property {Array<Array<string | null>>} pageLayouts
 * @property {Array<string | null>} dockIds
 * @property {string[]} installedAppIds
 * @property {string[]} seenApps
 * @property {string[]} removedAppIds
 * @property {string} [wallpaper]
 */

function cloneSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== 'object') return null
  return {
    pageLayouts: Array.isArray(snapshot.pageLayouts)
      ? snapshot.pageLayouts.map(page => (Array.isArray(page) ? [...page] : []))
      : [],
    dockIds: Array.isArray(snapshot.dockIds) ? [...snapshot.dockIds] : [],
    installedAppIds: Array.isArray(snapshot.installedAppIds) ? [...snapshot.installedAppIds] : [],
    seenApps: Array.isArray(snapshot.seenApps) ? [...snapshot.seenApps] : [],
    removedAppIds: Array.isArray(snapshot.removedAppIds) ? [...snapshot.removedAppIds] : [],
    wallpaper: typeof snapshot.wallpaper === 'string' ? snapshot.wallpaper : 'default',
  }
}

/** @returns {PhoneLayoutCacheSnapshot | null} */
export function readPhoneLayoutCache() {
  if (memorySnapshot) {
    return cloneSnapshot(memorySnapshot)
  }
  if (typeof sessionStorage === 'undefined') return null
  try {
    const raw = sessionStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    memorySnapshot = cloneSnapshot(parsed)
    return cloneSnapshot(memorySnapshot)
  } catch {
    return null
  }
}

export function clearPhoneLayoutCache() {
  memorySnapshot = null
  if (typeof sessionStorage === 'undefined') return
  try {
    sessionStorage.removeItem(CACHE_KEY)
  } catch {
  }
}

/** @param {PhoneLayoutCacheSnapshot} snapshot */
export function writePhoneLayoutCache(snapshot) {
  const cloned = cloneSnapshot(snapshot)
  if (!cloned || cloned.pageLayouts.length === 0) return
  memorySnapshot = cloned
  if (typeof sessionStorage === 'undefined') return
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify(cloned))
  } catch {
    // private mode / quota
  }
}
