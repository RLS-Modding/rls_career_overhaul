<template>
  <PhoneWrapper app-name="Gallery" status-font-color="#FFFFFF" status-blend-mode="normal">
    <!-- Full-screen photo view -->
    <Transition name="fullscreen">
      <div v-if="selectedPhoto" class="gallery-fullscreen" @click="closeFullScreen">
        <div class="fullscreen-bar">
          <button
            type="button"
            class="fullscreen-back"
            @click.stop="closeFullScreen"
            aria-label="Back to gallery"
          >
            <BngIcon :type="icons.general?.arrow_small_left || 'general/arrow_small-left'" class="back-icon" />
            <span>Back</span>
          </button>
        </div>
        <div class="fullscreen-image-wrap" @click.stop>
          <Transition name="photo-fade" mode="out-in">
            <img
              v-if="fullScreenDataUrl"
              :key="selectedPhoto.filename"
              :src="fullScreenDataUrl"
              class="fullscreen-image"
              alt="Photo"
              @click.stop
            />
            <div v-else key="loading" class="fullscreen-loading">
              <div class="fullscreen-spinner"></div>
              <span>Loading...</span>
            </div>
          </Transition>
        </div>
      </div>
    </Transition>

    <!-- Grid view -->
    <Transition name="grid-fade" mode="out-in">
      <div v-if="!selectedPhoto" class="gallery-container">
        <header class="gallery-header">
          <div class="header-content">
            <div class="header-icon-wrap">
              <BngIcon :type="icons.photo" class="header-icon" />
            </div>
            <h1 class="header-title">Photos</h1>
          </div>
          <button
            v-if="!deleteMode && photos.length > 0"
            type="button"
            class="header-delete-btn"
            aria-label="Select photos to delete"
            @click="enterDeleteMode"
          >
            <span class="delete-btn-icon" aria-hidden="true">⌫</span>
            <span>Delete</span>
          </button>
          <button
            v-if="deleteMode"
            type="button"
            class="header-cancel-btn"
            @click="exitDeleteMode"
          >
            Cancel
          </button>
        </header>

        <div v-if="loading" class="gallery-loading">
          <div class="loading-spinner"></div>
          <span class="loading-text">Loading photos...</span>
        </div>

        <div v-else-if="photos.length === 0" class="gallery-empty">
          <div class="empty-icon-wrap">
            <BngIcon :type="icons.photo" class="empty-icon" />
          </div>
          <p class="empty-title">No photos yet</p>
          <p class="empty-hint">Take photos with the Camera app</p>
        </div>

        <div v-else class="gallery-grid">
          <button
            v-for="(photo, index) in photos"
            :key="photo.filename"
            class="gallery-tile"
            :class="{ selected: deleteMode && selectedForDelete.has(photo.filename) }"
            :style="{ '--delay': `${Math.min(index * 30, 300)}ms` }"
            @click="deleteMode ? toggleSelect(photo) : openPhoto(photo)"
          >
            <Transition name="tile-img" mode="out-in">
              <img
                v-if="photo.dataUrl"
                :src="photo.dataUrl"
                class="tile-image"
                :alt="photo.name"
                loading="lazy"
              />
              <div v-else class="tile-placeholder">
                <div class="tile-skeleton"></div>
                <BngIcon :type="icons.photo" class="tile-placeholder-icon" />
              </div>
            </Transition>
            <div v-if="deleteMode" class="tile-select-overlay">
              <span class="tile-check" :class="{ checked: selectedForDelete.has(photo.filename) }">✓</span>
            </div>
          </button>
        </div>

        <!-- Bottom bar: Delete (N) when in delete mode with selection -->
        <Transition name="bar-slide">
          <div v-if="deleteMode && selectedForDelete.size > 0" class="gallery-delete-bar">
            <button
              type="button"
              class="delete-confirm-btn"
              @click="showDeleteConfirm = true"
            >
              Delete ({{ selectedForDelete.size }})
            </button>
          </div>
        </Transition>

        <!-- Delete confirmation modal -->
        <Transition name="modal-fade">
          <div v-if="showDeleteConfirm" class="gallery-confirm-overlay" @click.self="showDeleteConfirm = false">
            <div class="gallery-confirm-modal">
              <p class="confirm-title">Delete {{ selectedForDelete.size }} photo{{ selectedForDelete.size === 1 ? '' : 's' }}?</p>
              <p class="confirm-message">This cannot be undone.</p>
              <div class="confirm-actions">
                <button type="button" class="confirm-btn cancel-btn" @click="showDeleteConfirm = false">Cancel</button>
                <button type="button" class="confirm-btn delete-btn" @click="confirmDelete">Delete</button>
              </div>
            </div>
          </div>
        </Transition>
      </div>
    </Transition>
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
const deleteMode = ref(false)
const selectedForDelete = ref(new Set())
const showDeleteConfirm = ref(false)

const BATCH_SIZE = 8
const BATCH_DELAY_MS = 100

function enterDeleteMode() {
  deleteMode.value = true
  selectedForDelete.value = new Set()
}

function exitDeleteMode() {
  deleteMode.value = false
  selectedForDelete.value = new Set()
}

function toggleSelect(photo) {
  const next = new Set(selectedForDelete.value)
  if (next.has(photo.filename)) next.delete(photo.filename)
  else next.add(photo.filename)
  selectedForDelete.value = next
}

async function confirmDelete() {
  showDeleteConfirm.value = false
  const toDelete = Array.from(selectedForDelete.value)
  if (toDelete.length === 0) return
  try {
    const removed = await lua.gameplay_phoneCamera.deletePhotos(toDelete)
    photos.value = photos.value.filter(p => !toDelete.includes(p.filename))
    exitDeleteMode()
  } catch (e) {
    console.error('deletePhotos failed', e)
  }
}

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
  if (deleteMode.value) return
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
/* Design tokens – match camera app, in-game feel */
$glass-bg: rgba(12, 12, 18, 0.92);
$glass-border: rgba(255, 255, 255, 0.06);
$glass-blur: 12px;
$surface: rgba(255, 255, 255, 0.06);
$surface-hover: rgba(255, 255, 255, 0.1);
$accent: rgba(255, 255, 255, 0.95);
$accent-dim: rgba(255, 255, 255, 0.5);
$ease-out: cubic-bezier(0.22, 1, 0.36, 1);
$ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);

.gallery-container {
  position: relative;
  padding: 14px;
  padding-top: 10px;
  height: 100%;
  display: flex;
  flex-direction: column;
  box-sizing: border-box;
  background: linear-gradient(180deg, rgba(8, 9, 12, 0.97) 0%, rgba(12, 14, 18, 0.98) 100%);
}

.gallery-header {
  flex-shrink: 0;
  margin-bottom: 14px;
  padding-bottom: 12px;
  border-bottom: 1px solid $glass-border;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.header-content {
  display: flex;
  align-items: center;
  gap: 12px;
}

.header-delete-btn,
.header-cancel-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 12px;
  border-radius: 10px;
  border: 1px solid $glass-border;
  font-size: 0.85rem;
  font-weight: 500;
  cursor: pointer;
  transition: background 0.2s $ease-out, color 0.2s $ease-out, transform 0.15s $ease-out;
}

.header-delete-btn {
  background: $surface;
  color: $accent-dim;

  .delete-btn-icon {
    font-size: 1.1em;
    opacity: 0.9;
  }

  &:hover {
    background: rgba(220, 80, 80, 0.25);
    color: rgba(255, 200, 200, 0.95);
  }
}

.header-cancel-btn {
  background: $surface;
  color: $accent;

  &:hover {
    background: $surface-hover;
  }
}

.header-icon-wrap {
  width: 36px;
  height: 36px;
  border-radius: 10px;
  background: $surface;
  border: 1px solid $glass-border;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.2s $ease-out, transform 0.15s $ease-out;

  &:hover {
    background: $surface-hover;
  }
}

.header-icon {
  font-size: 1.25em;
  color: $accent;
}

.header-title {
  margin: 0;
  font-size: 1.35rem;
  font-weight: 600;
  color: $accent;
  letter-spacing: -0.02em;
}

/* Loading state */
.gallery-loading {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 16px;
  color: $accent-dim;
  animation: contentFadeIn 0.35s $ease-out;
}

.loading-spinner {
  width: 36px;
  height: 36px;
  border: 3px solid rgba(255, 255, 255, 0.15);
  border-top-color: $accent;
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}

.loading-text {
  font-size: 0.9rem;
  letter-spacing: 0.02em;
}

/* Empty state */
.gallery-empty {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 14px;
  padding: 24px;
  animation: contentFadeIn 0.35s $ease-out;
}

.empty-icon-wrap {
  width: 72px;
  height: 72px;
  border-radius: 20px;
  background: $surface;
  border: 1px solid $glass-border;
  display: flex;
  align-items: center;
  justify-content: center;
  animation: emptyPulse 2.5s $ease-in-out infinite;
}

.empty-icon {
  font-size: 2.2em;
  color: $accent-dim;
  opacity: 0.7;
}

.empty-title {
  margin: 0;
  font-size: 1.1rem;
  font-weight: 600;
  color: $accent;
}

.empty-hint {
  margin: 0;
  font-size: 0.85rem;
  color: $accent-dim;
  opacity: 0.9;
}

/* Grid – 3 columns, tiles side by side with gaps (no stacking) */
.gallery-grid {
  flex: 1;
  min-height: 0;
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  grid-auto-rows: auto; /* row height from content (square tiles) */
  grid-auto-flow: row;
  column-gap: 12px;
  row-gap: 12px;
  align-content: start;
  overflow-y: auto;
  padding-bottom: 80px; /* room for delete bar */
  animation: contentFadeIn 0.3s $ease-out;
}

/* Square tile: use padding-bottom so height follows width (reliable grid layout) */
.gallery-tile {
  position: relative;
  width: 100%;
  height: 0;
  padding-bottom: 100%; /* square */
  padding-left: 0;
  padding-right: 0;
  border: none;
  border-radius: 12px;
  overflow: hidden;
  background: $surface;
  cursor: pointer;
  display: block;
  animation: tileStagger 0.4s $ease-out backwards;
  animation-delay: var(--delay, 0ms);
  transition: transform 0.2s $ease-out, box-shadow 0.2s $ease-out, background 0.2s $ease-out, border-color 0.2s $ease-out;
  box-sizing: border-box;
  border: 1px solid $glass-border;

  &:hover {
    transform: scale(1.03);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    background: $surface-hover;
    border-color: rgba(255, 255, 255, 0.1);
  }

  &:active {
    transform: scale(0.98);
    transition-duration: 0.1s;
  }

  &.selected {
    border-color: rgba(255, 180, 180, 0.5);
    box-shadow: 0 0 0 2px rgba(220, 80, 80, 0.4);
  }
}

.tile-select-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: flex-start;
  justify-content: flex-end;
  padding: 8px;
  pointer-events: none;
}

.tile-check {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 2px solid rgba(255, 255, 255, 0.6);
  background: rgba(0, 0, 0, 0.35);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.75rem;
  font-weight: bold;
  color: transparent;
  transition: background 0.2s $ease-out, border-color 0.2s $ease-out, color 0.2s $ease-out;

  &.checked {
    background: rgba(220, 80, 80, 0.9);
    border-color: rgba(255, 255, 255, 0.9);
    color: #fff;
  }
}

.tile-image {
  position: absolute;
  left: 0;
  top: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  transition: transform 0.25s $ease-out;
}

.gallery-tile:hover .tile-image {
  transform: scale(1.05);
}

.tile-placeholder {
  position: absolute;
  left: 0;
  top: 0;
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}

.tile-skeleton {
  position: absolute;
  inset: 0;
  background: linear-gradient(
    110deg,
    rgba(255, 255, 255, 0.04) 25%,
    rgba(255, 255, 255, 0.08) 50%,
    rgba(255, 255, 255, 0.04) 75%
  );
  background-size: 200% 100%;
  animation: skeletonShine 1.2s ease-in-out infinite;
}

.tile-placeholder-icon {
  font-size: 1.8em;
  color: $accent-dim;
  opacity: 0.5;
  position: relative;
  z-index: 1;
}

/* Delete bar – center bottom */
.gallery-delete-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 14px 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: $glass-bg;
  backdrop-filter: blur($glass-blur);
  -webkit-backdrop-filter: blur($glass-blur);
  border-top: 1px solid $glass-border;
}

.delete-confirm-btn {
  padding: 12px 28px;
  border-radius: 12px;
  border: none;
  background: rgba(200, 60, 60, 0.85);
  color: #fff;
  font-size: 1rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.2s $ease-out, transform 0.15s $ease-out;

  &:hover {
    background: rgba(220, 70, 70, 0.95);
    transform: scale(1.02);
  }

  &:active {
    transform: scale(0.98);
  }
}

.bar-slide-enter-active,
.bar-slide-leave-active {
  transition: transform 0.25s $ease-out, opacity 0.2s $ease-out;
}
.bar-slide-enter-from,
.bar-slide-leave-to {
  transform: translateY(100%);
  opacity: 0;
}

/* Delete confirmation modal */
.gallery-confirm-overlay {
  position: absolute;
  inset: 0;
  z-index: 20;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
  background: rgba(0, 0, 0, 0.6);
  backdrop-filter: blur(4px);
}

.gallery-confirm-modal {
  background: $glass-bg;
  border: 1px solid $glass-border;
  border-radius: 16px;
  padding: 20px;
  max-width: 280px;
  width: 100%;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.5);
}

.confirm-title {
  margin: 0 0 8px;
  font-size: 1.1rem;
  font-weight: 600;
  color: $accent;
}

.confirm-message {
  margin: 0 0 18px;
  font-size: 0.9rem;
  color: $accent-dim;
}

.confirm-actions {
  display: flex;
  gap: 10px;
  justify-content: flex-end;
}

.confirm-btn {
  padding: 10px 18px;
  border-radius: 10px;
  font-size: 0.9rem;
  font-weight: 500;
  cursor: pointer;
  transition: background 0.2s $ease-out, transform 0.15s $ease-out;

  &:active {
    transform: scale(0.98);
  }
}

.confirm-btn.cancel-btn {
  background: $surface;
  border: 1px solid $glass-border;
  color: $accent;

  &:hover {
    background: $surface-hover;
  }
}

.confirm-btn.delete-btn {
  background: rgba(200, 60, 60, 0.9);
  border: none;
  color: #fff;

  &:hover {
    background: rgba(220, 70, 70, 1);
  }
}

.modal-fade-enter-active,
.modal-fade-leave-active {
  transition: opacity 0.2s $ease-out;
}
.modal-fade-enter-from,
.modal-fade-leave-to {
  opacity: 0;
}

/* Full-screen view */
.gallery-fullscreen {
  position: absolute;
  inset: 0;
  background: #060608;
  z-index: 10;
  display: flex;
  flex-direction: column;
  align-items: stretch;
}

.fullscreen-bar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  min-height: 48px;
  padding: 10px 14px;
  background: $glass-bg;
  backdrop-filter: blur($glass-blur);
  -webkit-backdrop-filter: blur($glass-blur);
  border-bottom: 1px solid $glass-border;
  z-index: 2;
}

.fullscreen-back {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: $surface;
  border: 1px solid $glass-border;
  border-radius: 10px;
  color: $accent;
  font-size: 0.9rem;
  font-weight: 500;
  cursor: pointer;
  transition: background 0.2s $ease-out, transform 0.15s $ease-out;

  .back-icon {
    font-size: 1.1em;
  }

  &:hover {
    background: $surface-hover;
  }

  &:active {
    transform: scale(0.98);
  }
}

.fullscreen-image-wrap {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 0;
  padding: 56px 12px 12px;
}

.fullscreen-image {
  max-width: 100%;
  max-height: 100%;
  width: auto;
  height: auto;
  object-fit: contain;
  border-radius: 4px;
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.5);
}

.fullscreen-loading {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  color: $accent-dim;
  font-size: 0.9rem;
}

.fullscreen-spinner {
  width: 32px;
  height: 32px;
  border: 3px solid rgba(255, 255, 255, 0.15);
  border-top-color: $accent;
  border-radius: 50%;
  animation: spin 0.7s linear infinite;
}

/* Transitions */
.fullscreen-enter-active,
.fullscreen-leave-active {
  transition: opacity 0.25s $ease-out;
}
.fullscreen-enter-from,
.fullscreen-leave-to {
  opacity: 0;
}

.grid-fade-enter-active,
.grid-fade-leave-active {
  transition: opacity 0.2s $ease-out;
}
.grid-fade-enter-from,
.grid-fade-leave-to {
  opacity: 0;
}

.photo-fade-enter-active,
.photo-fade-leave-active {
  transition: opacity 0.2s $ease-out;
}
.photo-fade-enter-from,
.photo-fade-leave-to {
  opacity: 0;
}

.tile-img-enter-active,
.tile-img-leave-active {
  transition: opacity 0.2s $ease-out;
}
.tile-img-enter-from,
.tile-img-leave-to {
  opacity: 0;
}

/* Keyframes */
@keyframes spin {
  to { transform: rotate(360deg); }
}

@keyframes contentFadeIn {
  from { opacity: 0; }
  to { opacity: 1; }
}

@keyframes tileStagger {
  from {
    opacity: 0;
    transform: scale(0.92) translateY(8px);
  }
  to {
    opacity: 1;
    transform: scale(1) translateY(0);
  }
}

@keyframes emptyPulse {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.85; transform: scale(1.02); }
}

@keyframes skeletonShine {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}
</style>
