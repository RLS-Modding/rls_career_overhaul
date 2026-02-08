<template>
  <PhoneWrapper app-name="Gallery" status-font-color="#FFFFFF" status-blend-mode="normal">
    <!-- Full-screen photo view (like iPhone Photos app) -->
    <div v-if="selectedPhoto" class="gallery-fullscreen" @click="closeFullScreen">
      <button class="fullscreen-back" @click.stop="closeFullScreen" aria-label="Back">
        <BngIcon :type="icons.general?.arrow_small_left || 'general/arrow_small-left'" class="back-icon" />
        <span>Back</span>
      </button>
      <div class="fullscreen-image-wrap" @click.stop>
        <img
          v-if="fullScreenDataUrl"
          :src="fullScreenDataUrl"
          class="fullscreen-image"
          alt="Photo"
          @click.stop
        />
        <div v-else class="fullscreen-loading">
          <span>Loading...</span>
        </div>
      </div>
    </div>

    <!-- Grid view -->
    <div v-else class="gallery-container">
      <div class="gallery-header">
        <BngIcon :type="icons.photo" class="header-icon" />
        <h1>Photos</h1>
      </div>

      <div v-if="loading" class="gallery-loading">
        <div class="loading-spinner"></div>
        <span>Loading photos...</span>
      </div>

      <div v-else-if="photos.length === 0" class="gallery-empty">
        <BngIcon :type="icons.photo" class="empty-icon" />
        <p>No photos yet</p>
        <p class="hint">Take photos with the Camera app</p>
      </div>

      <div v-else class="gallery-grid">
        <button
          v-for="photo in photos"
          :key="photo.filename"
          class="gallery-tile"
          @click="openPhoto(photo)"
        >
          <img
            v-if="photo.dataUrl"
            :src="photo.dataUrl"
            class="tile-image"
            :alt="photo.name"
            loading="lazy"
          />
          <div v-else class="tile-placeholder">
            <BngIcon :type="icons.photo" class="tile-placeholder-icon" />
          </div>
        </button>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
import { BngIcon, icons } from '@/common/components/base'
import { ref, onMounted } from 'vue'
import { lua } from '@/bridge'

const photos = ref([])
const loading = ref(true)
const selectedPhoto = ref(null)
const fullScreenDataUrl = ref(null)

const BATCH_SIZE = 8
const BATCH_DELAY_MS = 100

async function loadList() {
  loading.value = true
  try {
    const list = await lua.gameplay_phoneCamera.getPhotoList()
    photos.value = Array.isArray(list) ? list.map(p => ({ ...p, dataUrl: null })) : []
    loading.value = false
    loadThumbnailsInBatches()
  } catch (e) {
    console.error('Gallery getPhotoList failed', e)
    photos.value = []
    loading.value = false
  }
}

function loadThumbnailsInBatches() {
  const items = photos.value.filter(p => !p.dataUrl)
  let index = 0
  function runBatch() {
    const batch = items.slice(index, index + BATCH_SIZE)
    index += BATCH_SIZE
    batch.forEach(async (photo) => {
      try {
        const url = await lua.gameplay_phoneCamera.getPhotoAsDataUrl(photo.filename)
        const p = photos.value.find(x => x.filename === photo.filename)
        if (p && url) p.dataUrl = url
      } catch (_) {}
    })
    if (index < items.length) setTimeout(runBatch, BATCH_DELAY_MS)
  }
  if (items.length) runBatch()
}

async function openPhoto(photo) {
  selectedPhoto.value = photo
  if (photo.dataUrl) {
    fullScreenDataUrl.value = photo.dataUrl
    return
  }
  fullScreenDataUrl.value = null
  try {
    const url = await lua.gameplay_phoneCamera.getPhotoAsDataUrl(photo.filename)
    fullScreenDataUrl.value = url
    const p = photos.value.find(x => x.filename === photo.filename)
    if (p) p.dataUrl = url
  } catch (e) {
    console.error('getPhotoAsDataUrl failed', e)
  }
}

function closeFullScreen() {
  selectedPhoto.value = null
  fullScreenDataUrl.value = null
}

onMounted(() => {
  loadList()
})
</script>

<style scoped lang="scss">
.gallery-container {
  padding: 12px;
  padding-top: 8px;
  height: 100%;
  display: flex;
  flex-direction: column;
  box-sizing: border-box;
}

.gallery-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
  flex-shrink: 0;

  .header-icon {
    font-size: 1.5em;
    color: #fff;
  }

  h1 {
    margin: 0;
    font-size: 1.25rem;
    color: #fff;
    font-weight: 600;
  }
}

.gallery-loading,
.gallery-empty {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  color: rgba(255, 255, 255, 0.8);

  .loading-spinner {
    width: 32px;
    height: 32px;
    border: 3px solid rgba(255, 255, 255, 0.3);
    border-top-color: #fff;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .empty-icon {
    font-size: 3em;
    opacity: 0.5;
  }

  .hint {
    font-size: 0.85rem;
    opacity: 0.8;
  }
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.gallery-grid {
  flex: 1;
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  column-gap: 6px;
  row-gap: 6px;
  align-content: start;
  overflow-y: auto;
  padding-bottom: 12px;
}

.gallery-tile {
  aspect-ratio: 1;
  padding: 0;
  border: none;
  border-radius: 8px;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.08);
  cursor: pointer;
  display: block;
  min-height: 0;

  &:hover {
    background: rgba(255, 255, 255, 0.12);
  }
}

.tile-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.tile-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;

  .tile-placeholder-icon {
    font-size: 2em;
    color: rgba(255, 255, 255, 0.4);
  }
}

/* Full-screen view (fills phone screen) */
.gallery-fullscreen {
  position: absolute;
  inset: 0;
  background: #000;
  z-index: 10;
  display: flex;
  flex-direction: column;
  align-items: stretch;
}

.fullscreen-back {
  position: absolute;
  top: 8px;
  left: 8px;
  z-index: 2;
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 12px;
  background: rgba(0, 0, 0, 0.5);
  border: none;
  border-radius: 8px;
  color: #fff;
  font-size: 0.95rem;
  cursor: pointer;

  .back-icon {
    font-size: 1.2em;
  }

  &:hover {
    background: rgba(0, 0, 0, 0.7);
  }
}

.fullscreen-image-wrap {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 0;
  padding: 40px 8px 8px;
}

.fullscreen-image {
  max-width: 100%;
  max-height: 100%;
  width: auto;
  height: auto;
  object-fit: contain;
}

.fullscreen-loading {
  color: rgba(255, 255, 255, 0.7);
}
</style>
