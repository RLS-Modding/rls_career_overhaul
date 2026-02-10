import { defineStore } from 'pinia'
import { ref } from 'vue'

export const usePhoneLayoutStore = defineStore('phoneLayout', () => {
  const pages = ref([])
  const dock = ref([])
  const wallpaper = ref('default')
  const seenApps = ref(new Set())
  const layoutLoaded = ref(false)

  function setLayout(data) {
    if (!data) return
    pages.value = data.pages || []
    dock.value = data.dock || []
    wallpaper.value = data.wallpaper || 'default'
    seenApps.value = new Set(data.seenApps || [])
    layoutLoaded.value = true
  }

  function getLayoutData() {
    return {
      version: 1,
      wallpaper: wallpaper.value,
      pages: pages.value,
      dock: dock.value,
      seenApps: [...seenApps.value],
    }
  }

  function markSeen(appId) {
    seenApps.value.add(appId)
  }

  return { pages, dock, wallpaper, seenApps, layoutLoaded, setLayout, getLayoutData, markSeen }
})
