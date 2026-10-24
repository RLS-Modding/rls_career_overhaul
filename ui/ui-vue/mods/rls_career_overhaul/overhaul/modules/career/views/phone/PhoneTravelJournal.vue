<template>
  <div class="journal" v-bng-on-ui-nav:tab_l.asMouse="previousMap" v-bng-on-ui-nav:tab_r.asMouse="nextMap">
    <div v-if="loading" class="center-state">
      <div class="spinner"></div>
      <span>Opening journal…</span>
    </div>

    <div v-else-if="error" class="center-state error-state">
      <strong>Journal unavailable</strong>
      <span>{{ error }}</span>
      <button @click="loadState">Try again</button>
    </div>

    <section v-else-if="review" class="review-page">
      <div class="paper-heading">
        <span class="eyebrow">New memories</span>
        <h1>Choose a cover</h1>
        <p>{{ reviewLocation?.name }}</p>
      </div>
      <div class="review-grid">
        <button
          v-for="photo in reviewPhotos"
          :key="photo.id"
          class="polaroid review-photo"
          :class="{ selected: reviewSelection === photo.id }"
          @click="reviewSelection = photo.id"
        >
          <span class="photo-window">
            <img v-if="photoUrl(review.mapId, review.locationId, photo.id)" :src="photoUrl(review.mapId, review.locationId, photo.id)" alt="New journal photograph" />
            <span v-else class="photo-loading"><span class="spinner small"></span></span>
          </span>
          <span class="hand-label">{{ formatDate(photo.capturedAt) }}</span>
        </button>
      </div>
      <div class="review-actions">
        <button class="paper-button quiet" @click="finishReview(null)">Use first photo</button>
        <button class="paper-button primary" :disabled="!reviewSelection" @click="finishReview(reviewSelection)">Set cover</button>
      </div>
      <p v-if="actionFeedback" class="action-feedback" :class="{ error: actionFeedbackError }">{{ actionFeedback }}</p>
    </section>

    <section v-else-if="selectedLocation" class="album-page">
      <header class="album-header">
        <button class="back-chip" @click="closeAlbum">‹ Map</button>
        <div>
          <span class="eyebrow">{{ selectedMap?.name }}</span>
          <h1>{{ selectedLocation.name }}</h1>
        </div>
        <span class="status-sticker" :class="selectedLocation.status">{{ statusLabel(selectedLocation.status) }}</span>
      </header>

      <div class="location-note">
        <p>{{ selectedLocation.description }}</p>
        <span v-if="selectedLocation.insideZone">You are inside the scenic area. Stop, then enter the photography scene here or use the normal Interact control after closing the phone.</span>
        <span v-else-if="selectedLocation.canNavigate">Select a route, drive into the scenic area, and stop to enter Photo Mode.</span>
        <span v-else>Load {{ selectedMap?.name }} to revisit this photography scene.</span>
      </div>

      <div class="location-actions">
        <button
          class="journal-action route-action"
          :class="{ active: routedLocationId === selectedLocation.id }"
          :disabled="routePending || !selectedLocation.canNavigate"
          @click="setRoute"
        >
          {{ !selectedLocation.canNavigate ? `Load ${selectedMap?.name} to route` : routePending ? 'Setting route...' : routedLocationId === selectedLocation.id ? 'Route selected' : 'Set route' }}
        </button>
        <button
          class="journal-action scene-action"
          :disabled="scenePending || !selectedLocation.canEnterScene"
          @click="enterPhotoScene"
        >
          {{ scenePending ? 'Opening Photo Mode...' : selectedLocation.insideZone ? 'Enter Photo Scene' : 'Drive into scenic area' }}
        </button>
      </div>
      <p v-if="actionFeedback" class="action-feedback" :class="{ error: actionFeedbackError }">{{ actionFeedback }}</p>

      <div class="section-title">
        <span>Featured photographs</span>
        <small>3 scrapbook slots</small>
      </div>
      <div class="featured-row">
        <article v-for="slot in 3" :key="slot" class="featured-slot">
          <template v-if="featuredPhotos[slot - 1]">
            <button class="featured-image" @click="openPreview(featuredPhotos[slot - 1])">
              <img v-if="photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" :src="photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" alt="Featured journal photograph" />
              <span v-else class="photo-loading"><span class="spinner small"></span></span>
            </button>
            <div class="slot-tools">
              <button :disabled="slot === 1" @click="moveFeatured(slot - 1, -1)">‹</button>
              <button title="Remove from featured" @click="removeFeatured(featuredPhotos[slot - 1].id)">×</button>
              <button :disabled="slot === featuredPhotos.length" @click="moveFeatured(slot - 1, 1)">›</button>
            </div>
          </template>
          <span v-else class="empty-feature">Photo {{ slot }}</span>
        </article>
      </div>

      <div class="section-title album-title">
        <span>Album</span>
        <small>{{ selectedLocation.photoCount }} photo{{ selectedLocation.photoCount === 1 ? '' : 's' }}</small>
      </div>
      <div v-if="selectedLocation.photos.length" class="album-grid">
        <article v-for="photo in selectedLocation.photos" :key="photo.id" class="album-photo">
          <button class="album-image" @click="openPreview(photo)">
            <img v-if="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" :src="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" alt="Journal photograph" loading="lazy" />
            <span v-else class="photo-loading"><span class="spinner small"></span></span>
            <span v-if="photo.cover" class="cover-ribbon">Cover</span>
          </button>
          <div class="album-tools">
            <button :class="{ active: photo.cover }" @click="setCover(photo.id)">Cover</button>
            <button :class="{ active: photo.featured }" @click="toggleFeatured(photo.id)">{{ photo.featured ? 'Unfeature' : 'Feature' }}</button>
            <button class="delete" @click="requestDelete(photo)">Delete</button>
          </div>
        </article>
      </div>
      <div v-else class="empty-album">
        <TravelJournalScenePlaceholder class="empty-frame" :status="selectedLocation.status" />
        <p v-if="selectedLocation.status === 'completed'">Your journal copy is empty. Completion and rewards are preserved.</p>
        <p v-else>Take a photograph during this location’s Photo Mode scene to complete it.</p>
      </div>
    </section>

    <section v-else-if="selectedMap" class="map-page">
      <header class="map-header">
        <button class="page-arrow" :disabled="mapIndex === 0" @click="previousMap">‹</button>
        <div>
          <span class="eyebrow">Travel Journal</span>
          <h1>{{ selectedMap.name }}</h1>
          <p>{{ selectedMap.completedCount }} / {{ selectedMap.totalCount }} locations complete</p>
        </div>
        <button class="page-arrow" :disabled="mapIndex >= maps.length - 1" @click="nextMap">›</button>
      </header>

      <div class="page-dots" aria-label="Map pages">
        <button v-for="(map, index) in maps" :key="map.id" :aria-label="`Show ${map.name}`" :aria-current="index === mapIndex ? 'page' : undefined" :class="{ active: index === mapIndex }" @click="mapIndex = index"></button>
      </div>

      <div class="location-stack">
        <button v-for="(location, index) in selectedMap.locations" :key="location.id" class="location-card" :style="{ '--tilt': `${(index % 2 ? 1 : -1) * (0.35 + index * 0.08)}deg` }" @click="openAlbum(location)">
          <span class="card-photo">
            <img v-if="cardImage(selectedMap, location)" :src="cardImage(selectedMap, location)" :alt="`${location.name} journal cover`" />
            <TravelJournalScenePlaceholder v-else class="card-placeholder" :status="location.status" />
          </span>
          <span class="card-copy">
            <span class="card-number">No. {{ String(index + 1).padStart(2, '0') }}</span>
            <strong>{{ location.name }}</strong>
            <span class="card-summary" :class="{ hint: location.status === 'notFound' }">{{ cardSummary(location) }}</span>
          </span>
          <span class="card-mark" :class="location.status">{{ location.status === 'completed' ? '✓' : location.status === 'discovered' ? 'FOUND' : '?' }}</span>
        </button>
      </div>

      <div class="map-stamp" :class="{ earned: selectedMap.stampAwarded }">
        <span class="stamp-ring">
          <b>{{ selectedMap.stampAwarded ? 'COMPLETE' : 'LOCKED' }}</b>
          <small>{{ selectedMap.stampLabel }}</small>
        </span>
        <p>{{ selectedMap.stampAwarded ? 'Map stamp earned, 5,000 Photography XP' : 'Complete all five locations to earn this map stamp.' }}</p>
      </div>
      <button class="open-journal-button" @click="openFullJournal">Open Journal</button>
    </section>

    <div v-if="previewPhoto" class="modal-backdrop" @click.self="closePreview">
      <div class="preview-card" v-bng-scoped-nav="modalScopes.preview" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <img v-if="previewUrl" :src="previewUrl" alt="Journal photograph preview" />
        <div v-else class="preview-loading"><span class="spinner"></span></div>
        <button bng-scoped-nav-autofocus @click="closePreview">Close</button>
      </div>
    </div>

    <div v-if="deleteTarget" class="modal-backdrop" @click.self="deleteTarget = null">
      <div class="confirm-card" v-bng-scoped-nav="modalScopes.delete" v-bc-modal-focus v-bng-on-ui-nav:back="closeTopLayer">
        <h2>Delete journal copy?</h2>
        <p>The ordinary BeamNG screenshot will remain untouched. Completion and XP will not change.</p>
        <p v-if="actionFeedbackError && actionFeedback" class="action-feedback error">{{ actionFeedback }}</p>
        <div>
          <button bng-scoped-nav-autofocus class="paper-button quiet" @click="deleteTarget = null">Cancel</button>
          <button class="paper-button danger" @click="confirmDelete">Delete</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>

import { vBngScopedNav, vBngOnUiNav } from '@/common/directives'
import { vBcModalFocus } from '../../components/businessComputer/bcModalNav.js'
import { usePhoneAppLayers, usePhoneAppFocus } from './controllerLayers.js'
import { reportUiFailure } from "../../utils/safeLua"
import TravelJournalScenePlaceholder from "../../components/TravelJournalScenePlaceholder.vue"

import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { runRaw, serialize } from '@/bridge/libs/Lua'
import { useEvents } from '@/services/events'


import { acquireScope } from '../../utils/luaScopes'

usePhoneAppFocus()


const events = useEvents()
const state = ref(null)
const loading = ref(true)
const error = ref('')
const mapIndex = ref(0)
const selectedLocationId = ref(null)
const reviewSelection = ref(null)
const previewPhoto = ref(null)
const deleteTarget = ref(null)
const { scopes: modalScopes, back: closeTopLayer } = usePhoneAppLayers({
  preview: { open: () => previewPhoto.value, close: () => closePreview() },
  delete: { open: () => deleteTarget.value, close: () => { deleteTarget.value = null } },
}, { onBack: handleBack })

const routePending = ref(false)
const scenePending = ref(false)
const routedLocationId = ref(null)
const actionFeedback = ref('')
const actionFeedbackError = ref(false)
const photoUrls = reactive({})
const photoRequests = new Set()
const MAX_PHOTO_CACHE_ENTRIES = 48

const callJournal = (method, ...args) =>
  runRaw(`overhaul_phone_travelJournal.${method}(${args.map(serialize).join(',')})`)

function normalizeJournalState(raw) {
  if (!raw || typeof raw !== 'object') return raw
  const normalizedMaps = Array.isArray(raw.maps) ? raw.maps.map(map => ({
    ...map,
    locations: Array.isArray(map.locations) ? map.locations.map(location => ({
      ...location,
      photos: Array.isArray(location.photos) ? location.photos : [],
      featuredPhotoIds: Array.isArray(location.featuredPhotoIds) ? location.featuredPhotoIds : [],
    })) : [],
  })) : []
  const pendingReview = raw.pendingReview && typeof raw.pendingReview === 'object'
    ? {...raw.pendingReview, photoIds: Array.isArray(raw.pendingReview.photoIds) ? raw.pendingReview.photoIds : []}
    : null
  return {...raw, maps: normalizedMaps, pendingReview}
}

const maps = computed(() => Array.isArray(state.value?.maps) ? state.value.maps : [])
const selectedMap = computed(() => maps.value[mapIndex.value] || null)
const selectedLocation = computed(() => selectedMap.value?.locations.find(location => location.id === selectedLocationId.value) || null)
const review = computed(() => state.value?.pendingReview || null)
const reviewMap = computed(() => maps.value.find(map => map.id === review.value?.mapId) || null)
const reviewLocation = computed(() => reviewMap.value?.locations.find(location => location.id === review.value?.locationId) || null)
const reviewPhotos = computed(() => {
  const ids = new Set(review.value?.photoIds || [])
  return reviewLocation.value?.photos.filter(photo => ids.has(photo.id)) || []
})
const featuredPhotos = computed(() => {
  if (!selectedLocation.value) return []
  return selectedLocation.value.featuredPhotoIds
    .map(id => selectedLocation.value.photos.find(photo => photo.id === id))
    .filter(Boolean)
})
const previewUrl = computed(() => {
  if (!previewPhoto.value || !selectedMap.value || !selectedLocation.value) return null
  return photoUrl(selectedMap.value.id, selectedLocation.value.id, previewPhoto.value.id)
})

function photoKey(mapId, locationId, photoId) {
  return `${mapId}/${locationId}/${photoId}`
}

function photoUrl(mapId, locationId, photoId) {
  if (!mapId || !locationId || !photoId) return null
  return photoUrls[photoKey(mapId, locationId, photoId)] || null
}

async function loadPhoto(mapId, locationId, photoId) {
  const key = photoKey(mapId, locationId, photoId)
  if (photoRequests.has(key)) return
  photoRequests.add(key)
  try {
    const url = await callJournal('getPhotoDataUrl', mapId, locationId, photoId)
    if (url) {
      photoUrls[key] = url
      const keys = Object.keys(photoUrls)
      if (keys.length > MAX_PHOTO_CACHE_ENTRIES) delete photoUrls[keys[0]]
    }
  } catch (_) { reportUiFailure(_, "load photo (PhoneTravelJournal)") } finally {
    photoRequests.delete(key)
  }
}

function queueVisiblePhotos() {
  const map = selectedMap.value
  if (!map) return
  for (const location of map.locations) {
    if (location.coverPhotoId) loadPhoto(map.id, location.id, location.coverPhotoId)
  }
  if (selectedLocation.value) {
    for (const photo of selectedLocation.value.photos) loadPhoto(map.id, selectedLocation.value.id, photo.id)
  }
  if (review.value && reviewLocation.value) {
    for (const photo of reviewPhotos.value) loadPhoto(review.value.mapId, review.value.locationId, photo.id)
  }
}

async function loadState() {
  loading.value = true
  error.value = ''
  try {
    await acquireScope(lua, 'phone.travelJournal')
    state.value = normalizeJournalState(await callJournal('getJournalState'))
    const currentIndex = maps.value.findIndex(map => map.current)
    if (currentIndex >= 0 && !selectedLocationId.value) mapIndex.value = currentIndex
    reviewSelection.value = reviewPhotos.value[0]?.id || null
    queueVisiblePhotos()
  } catch (err) {
    reportUiFailure(err, "[TravelJournal] load failed (PhoneTravelJournal)")
    error.value = 'The career journal service could not be loaded.'
  } finally {
    loading.value = false
  }
}

function applyState(next) {
  if (!next || typeof next !== 'object') return
  const mapId = selectedMap.value?.id
  state.value = normalizeJournalState(next)
  if (mapId) {
    const nextIndex = maps.value.findIndex(map => map.id === mapId)
    if (nextIndex >= 0) mapIndex.value = nextIndex
  }
  if (selectedLocationId.value && !selectedLocation.value) selectedLocationId.value = null
  if (review.value && !reviewSelection.value) reviewSelection.value = reviewPhotos.value[0]?.id || null
  queueVisiblePhotos()
}

function cardImage(map, location) {
  if (location.status === 'completed') {
    return location.coverPhotoId ? photoUrl(map.id, location.id, location.coverPhotoId) : null
  }
  return null
}

function statusLabel(status) {
  if (status === 'completed') return 'Completed'
  if (status === 'discovered') return 'Discovered'
  return 'Not found'
}

// the card's one line under the name: where to look until found, then what is left to do
function cardSummary(location) {
  if (location.status === 'notFound') return location.description || 'Not found yet'
  if (location.status === 'discovered') return 'Found. Take a photo here to complete it.'
  return `${location.photoCount} photo${location.photoCount === 1 ? '' : 's'} in the album`
}

function formatDate(timestamp) {
  if (!timestamp) return 'New photo'
  return new Date(Number(timestamp) * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

function previousMap() {
  if (review.value || selectedLocation.value || mapIndex.value <= 0) return
  mapIndex.value -= 1
}

function nextMap() {
  if (review.value || selectedLocation.value || mapIndex.value >= maps.value.length - 1) return
  mapIndex.value += 1
}

function openAlbum(location) {
  selectedLocationId.value = location.id
  actionFeedback.value = ''
  actionFeedbackError.value = false
  queueVisiblePhotos()
}

function closeAlbum() {
  selectedLocationId.value = null
  previewPhoto.value = null
  actionFeedback.value = ''
}

function sceneFailureMessage(reason) {
  if (reason === 'outside_zone') return 'Drive into the scenic area before entering Photo Mode.'
  if (reason === 'trailer_attached') return 'Detach the trailer before entering the photography scene.'
  if (reason === 'activity_blocked') return 'Finish the current activity before entering the photography scene.'
  return 'The photography scene could not be opened.'
}

async function setRoute() {
  if (!selectedMap.value || !selectedLocation.value || routePending.value) return
  routePending.value = true
  actionFeedback.value = ''
  actionFeedbackError.value = false
  try {
    const result = await callJournal('setRouteToLocation', selectedMap.value.id, selectedLocation.value.id)
    if (result?.success) {
      routedLocationId.value = selectedLocation.value.id
      actionFeedback.value = `Navigation is now guiding you to ${selectedLocation.value.name}.`
    } else {
      actionFeedback.value = result?.reason === 'wrong_map'
        ? `Load ${selectedMap.value.name} before setting this route.`
        : 'Navigation is unavailable for this location.'
      actionFeedbackError.value = true
    }
  } catch (_) {
    actionFeedback.value = 'Navigation is unavailable for this location.'
    actionFeedbackError.value = true
  } finally {
    routePending.value = false
  }
}

async function enterPhotoScene() {
  if (!selectedMap.value || !selectedLocation.value || scenePending.value) return
  scenePending.value = true
  actionFeedback.value = ''
  actionFeedbackError.value = false
  try {
    const result = await callJournal('requestSceneFromPhone', selectedMap.value.id, selectedLocation.value.id)
    if (!result?.success) {
      actionFeedback.value = sceneFailureMessage(result?.reason)
      actionFeedbackError.value = true
      scenePending.value = false
    }
  } catch (_) {
    actionFeedback.value = 'The photography scene could not be opened.'
    actionFeedbackError.value = true
    scenePending.value = false
  }
}

function handleBack() {
  if (previewPhoto.value) {
    closePreview()
    return true
  }
  if (deleteTarget.value) {
    deleteTarget.value = null
    return true
  }
  if (review.value) {
    finishReview(null)
    return true
  }
  if (selectedLocation.value) {
    closeAlbum()
    return true
  }
  return false
}

async function openFullJournal() {
  await runRaw('extensions.ui_router.navigate("travel-journal")')
}

async function finishReview(photoId) {
  try {
    const result = await callJournal('completePendingReview', photoId || '')
    if (result === false) throw new Error('review_not_saved')
    reviewSelection.value = null
    await loadState()
  } catch (_) {
    actionFeedback.value = 'The photo review could not be saved. Please try again.'
    actionFeedbackError.value = true
  }
}

async function setCover(photoId) {
  try {
    const result = await callJournal('setCoverPhoto', selectedMap.value.id, selectedLocation.value.id, photoId)
    if (result === false) throw new Error('cover_not_saved')
    await loadState()
  } catch (_) {
    actionFeedback.value = 'The cover photo could not be changed.'
    actionFeedbackError.value = true
  }
}

async function saveFeatured(ids) {
  try {
    const result = await callJournal('setFeaturedPhotos', selectedMap.value.id, selectedLocation.value.id, ids)
    if (result === false) throw new Error('featured_not_saved')
    await loadState()
  } catch (_) {
    actionFeedback.value = 'The featured photos could not be updated.'
    actionFeedbackError.value = true
  }
}

function toggleFeatured(photoId) {
  const ids = [...selectedLocation.value.featuredPhotoIds]
  const index = ids.indexOf(photoId)
  if (index >= 0) ids.splice(index, 1)
  else if (ids.length < 3) ids.push(photoId)
  else ids[2] = photoId
  saveFeatured(ids)
}

function removeFeatured(photoId) {
  saveFeatured(selectedLocation.value.featuredPhotoIds.filter(id => id !== photoId))
}

function moveFeatured(index, direction) {
  const ids = [...selectedLocation.value.featuredPhotoIds]
  const target = index + direction
  if (target < 0 || target >= ids.length) return
  ;[ids[index], ids[target]] = [ids[target], ids[index]]
  saveFeatured(ids)
}

function openPreview(photo) {
  previewPhoto.value = photo
  loadPhoto(selectedMap.value.id, selectedLocation.value.id, photo.id)
}

function closePreview() {
  previewPhoto.value = null
}

function requestDelete(photo) {
  deleteTarget.value = photo
}

async function confirmDelete() {
  if (!deleteTarget.value) return
  const key = photoKey(selectedMap.value.id, selectedLocation.value.id, deleteTarget.value.id)
  try {
    const result = await callJournal('deletePhoto', selectedMap.value.id, selectedLocation.value.id, deleteTarget.value.id)
    if (result === false) throw new Error('delete_failed')
    delete photoUrls[key]
    deleteTarget.value = null
    await loadState()
  } catch (_) {
    actionFeedback.value = 'The photo could not be deleted.'
    actionFeedbackError.value = true
  }
}

watch([mapIndex, selectedLocationId], queueVisiblePhotos)

onMounted(() => {
  events.on('TravelJournalStateChanged', applyState)
  loadState()
})

onBeforeUnmount(() => {
  events.off('TravelJournalStateChanged', applyState)
})

</script>

<style scoped lang="scss">
$ink: #342a25;
$muted: #786a61;
$paper: #eee5d3;
$paper-dark: #d8c8ad;
$rose: #a95e62;
$green: #55735b;
$gold: #a47738;

.journal {
  position: relative;
  height: 100%;
  overflow-y: auto;
  box-sizing: border-box;
  padding: 3.15rem 0.72rem 1rem;
  color: $ink;
  background:
    radial-gradient(circle at 18% 10%, rgba(121, 84, 54, 0.08) 0 1px, transparent 1.5px),
    radial-gradient(circle at 80% 35%, rgba(121, 84, 54, 0.07) 0 1px, transparent 1.5px),
    linear-gradient(145deg, #f5efe4, #e6dcc9);
  background-size: 22px 25px, 31px 27px, auto;
  font-family: Georgia, 'Times New Roman', serif;
}

button { font: inherit; }

.center-state {
  min-height: 28rem;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  color: $muted;
  text-align: center;
}

.center-state button,
.back-chip,
.paper-button {
  border: 1px solid rgba(78, 58, 45, 0.25);
  border-radius: 0.3rem;
  padding: 0.48rem 0.7rem;
  color: $ink;
  background: #f8f1e3;
  box-shadow: 0 2px 5px rgba(53, 38, 27, 0.15);
}

.spinner {
  width: 1.7rem;
  height: 1.7rem;
  border: 3px solid rgba(83, 66, 54, 0.18);
  border-top-color: $rose;
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}

.spinner.small { width: 1rem; height: 1rem; border-width: 2px; }

.map-header,
.album-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.55rem;
  padding: 0.65rem 0.55rem;
  border-bottom: 1px dashed rgba(65, 47, 36, 0.28);
  text-align: center;
}

.map-header h1,
.album-header h1,
.paper-heading h1 {
  margin: 0.12rem 0;
  font-size: 1.26rem;
  line-height: 1.05;
  letter-spacing: -0.02em;
}

.map-header p,
.paper-heading p { margin: 0; color: $muted; font-size: 0.72rem; }
.eyebrow { color: $rose; font: 700 0.63rem/1.1 Arial, sans-serif; letter-spacing: 0.12em; text-transform: uppercase; }

.page-arrow {
  width: 2rem;
  height: 2rem;
  border: 0;
  border-radius: 50%;
  background: rgba(113, 80, 58, 0.1);
  color: $ink;
  font-size: 1.45rem;
}

.page-arrow:disabled { opacity: 0.22; }

.page-dots { display: flex; justify-content: center; gap: 0.35rem; padding: 0.55rem; }
.page-dots button { width: 0.42rem; height: 0.42rem; padding: 0; border: 0; border-radius: 50%; background: rgba(62, 43, 32, 0.25); }
.page-dots button.active { background: $rose; transform: scale(1.25); }

.location-stack { display: flex; flex-direction: column; gap: 0.62rem; padding: 0.2rem 0.12rem; }

.location-card {
  position: relative;
  min-height: 5.8rem;
  display: grid;
  grid-template-columns: 6.2rem 1fr 2.1rem;
  gap: 0.6rem;
  align-items: center;
  width: 100%;
  padding: 0.48rem;
  border: 0;
  color: $ink;
  background: rgba(255, 251, 241, 0.95);
  box-shadow: 0 4px 10px rgba(58, 39, 26, 0.17);
  transform: rotate(var(--tilt));
  text-align: left;
}

.location-card:active { transform: rotate(var(--tilt)) scale(0.985); }

.card-photo {
  height: 4.8rem;
  overflow: hidden;
  border: 0.28rem solid #fff;
  background: #cabfae;
  box-shadow: 0 2px 5px rgba(35, 26, 20, 0.2);
}

.card-photo img { width: 100%; height: 100%; object-fit: cover; display: block; }
.card-placeholder { font-size: 0.5rem; }

.card-copy { min-width: 0; display: flex; flex-direction: column; gap: 0.18rem; }
.card-copy strong { font-size: 0.94rem; line-height: 1.05; }
.card-summary { color: #5f5249; font: 0.64rem/1.3 Arial, sans-serif; }
.card-summary.hint { font-family: Georgia, 'Times New Roman', serif; font-style: italic; }
.card-number { color: $rose; font: 700 0.56rem Arial, sans-serif; letter-spacing: 0.08em; }

.card-mark {
  width: 1.8rem;
  height: 1.8rem;
  border: 2px solid rgba(89, 65, 48, 0.35);
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: $muted;
  font: 700 0.55rem Arial, sans-serif;
  transform: rotate(-9deg);
}
.card-mark.completed { color: $green; border-color: $green; font-size: 1rem; }
.card-mark.discovered { color: $gold; border-color: $gold; }

.map-stamp { margin: 1rem 0.3rem 0; padding: 0.8rem; display: flex; align-items: center; gap: 0.8rem; border-top: 1px dashed rgba(65, 47, 36, 0.25); opacity: 0.55; }
.map-stamp.earned { opacity: 1; }
.stamp-ring { width: 4.25rem; height: 4.25rem; flex: 0 0 auto; border: 3px double $rose; border-radius: 50%; display: flex; flex-direction: column; align-items: center; justify-content: center; color: $rose; transform: rotate(-8deg); text-align: center; }
.stamp-ring b { font: 800 0.58rem Arial, sans-serif; letter-spacing: 0.08em; }
.stamp-ring small { max-width: 3.5rem; font-size: 0.48rem; }
.map-stamp p { margin: 0; color: $muted; font-size: 0.68rem; line-height: 1.35; }
.open-journal-button { width: calc(100% - 0.6rem); min-height: 2.75rem; margin: 0.85rem 0.3rem 0; border: 1px solid #3f5946; border-radius: 0.35rem; color: #fff; background: $green; box-shadow: 0 3px 8px rgba(44, 65, 50, 0.28); font: 700 0.75rem Arial, sans-serif; letter-spacing: 0.04em; text-transform: uppercase; }
.open-journal-button:active { transform: translateY(1px); }

.album-header { text-align: left; }
.album-header > div { flex: 1; min-width: 0; }
.back-chip { padding: 0.35rem 0.48rem; }
.status-sticker { border: 2px solid $muted; border-radius: 0.2rem; padding: 0.24rem 0.35rem; color: $muted; font: 700 0.48rem Arial, sans-serif; text-transform: uppercase; transform: rotate(5deg); }
.status-sticker.completed { color: $green; border-color: $green; }
.status-sticker.discovered { color: $gold; border-color: $gold; }

.location-note { margin: 0.65rem 0.2rem 0.8rem; padding: 0.65rem; background: rgba(255, 248, 210, 0.72); box-shadow: 0 2px 6px rgba(67, 44, 29, 0.12); transform: rotate(-0.4deg); }
.location-note p { margin: 0 0 0.32rem; font-size: 0.76rem; line-height: 1.3; }
.location-note span { color: $muted; font: 0.62rem/1.25 Arial, sans-serif; }

.location-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 0.45rem; margin: 0 0.2rem 0.72rem; }
.journal-action { min-height: 2.5rem; border: 1px solid rgba(78, 58, 45, 0.3); border-radius: 0.3rem; padding: 0.48rem 0.55rem; color: $ink; background: #f8f1e3; box-shadow: 0 2px 5px rgba(53, 38, 27, 0.15); font: 700 0.65rem/1.15 Arial, sans-serif; }
.journal-action.route-action { color: white; border-color: $rose; background: $rose; }
.journal-action.route-action.active { border-color: $green; background: $green; }
.journal-action.scene-action { color: white; border-color: $green; background: $green; }
.journal-action:disabled { opacity: 0.42; box-shadow: none; }
.action-feedback { margin: -0.32rem 0.35rem 0.72rem; color: $green; font: 700 0.6rem/1.25 Arial, sans-serif; }
.action-feedback.error { color: #9f4c4c; }

.section-title { display: flex; justify-content: space-between; align-items: baseline; margin: 0.45rem 0.2rem; border-bottom: 1px solid rgba(72, 49, 34, 0.18); padding-bottom: 0.25rem; }
.section-title span { font-size: 0.84rem; font-weight: 700; }
.section-title small { color: $muted; font: 0.58rem Arial, sans-serif; }
.album-title { margin-top: 0.9rem; }

.featured-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.42rem; }
.featured-slot { min-width: 0; min-height: 5.7rem; padding: 0.28rem; background: rgba(255, 253, 247, 0.92); box-shadow: 0 2px 5px rgba(50, 34, 22, 0.14); }
.featured-image { width: 100%; height: 4.1rem; padding: 0; border: 0; background: #cfc4b2; overflow: hidden; }
.featured-image img, .album-image img { width: 100%; height: 100%; display: block; object-fit: cover; }
.slot-tools { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.12rem; margin-top: 0.2rem; }
.slot-tools button { border: 0; background: rgba(98, 68, 48, 0.08); color: $muted; }
.slot-tools button:disabled { opacity: 0.25; }
.empty-feature { min-height: 5.2rem; border: 1px dashed rgba(79, 58, 43, 0.3); display: flex; align-items: center; justify-content: center; color: rgba(79, 58, 43, 0.45); font-size: 0.62rem; }

.album-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.55rem; padding-bottom: 0.7rem; }
.album-photo { min-width: 0; padding: 0.32rem; background: #fffaf0; box-shadow: 0 3px 8px rgba(57, 39, 26, 0.15); }
.album-image { position: relative; width: 100%; height: 7.1rem; padding: 0; border: 0; overflow: hidden; background: #cfc4b2; }
.cover-ribbon { position: absolute; top: 0.35rem; left: -0.2rem; padding: 0.18rem 0.45rem; color: #fff; background: $rose; font: 700 0.52rem Arial, sans-serif; transform: rotate(-4deg); }
.album-tools { display: flex; flex-wrap: wrap; gap: 0.2rem; margin-top: 0.3rem; }
.album-tools button { flex: 1 1 auto; border: 1px solid rgba(72, 51, 37, 0.18); border-radius: 0.2rem; padding: 0.24rem; color: $muted; background: transparent; font: 0.52rem Arial, sans-serif; }
.album-tools button.active { color: $green; border-color: rgba(85, 115, 91, 0.55); background: rgba(85, 115, 91, 0.09); }
.album-tools button.delete { color: #9f4c4c; }
.photo-loading { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: #d8cebc; }

.empty-album { min-height: 9rem; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; color: $muted; }
.empty-album p { max-width: 16rem; font-size: 0.68rem; line-height: 1.35; }
.empty-frame { width: 6rem; height: 4rem; border: 0.35rem solid white; font-size: 0.5rem; box-shadow: 0 3px 7px rgba(45, 32, 23, 0.18); transform: rotate(-2deg); }

.paper-heading { text-align: center; padding: 0.75rem 0.4rem; }
.review-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 0.65rem; }
.polaroid { padding: 0.42rem 0.42rem 0.6rem; border: 0; background: #fffcf5; box-shadow: 0 4px 9px rgba(54, 37, 25, 0.2); transform: rotate(-1deg); }
.polaroid:nth-child(even) { transform: rotate(1.2deg); }
.polaroid.selected { box-shadow: 0 0 0 3px $rose, 0 6px 12px rgba(54, 37, 25, 0.25); }
.photo-window { display: block; height: 8rem; background: #d5c9b7; }
.photo-window img { width: 100%; height: 100%; object-fit: cover; }
.hand-label { display: block; margin-top: 0.35rem; color: $muted; font-size: 0.62rem; }
.review-actions { position: sticky; bottom: -1rem; display: flex; justify-content: flex-end; gap: 0.45rem; margin: 0.8rem -0.72rem -1rem; padding: 0.7rem; background: rgba(235, 225, 207, 0.96); border-top: 1px solid rgba(73, 50, 35, 0.16); }
.paper-button.primary { color: white; background: $green; }
.paper-button.danger { color: white; background: #984c4c; }
.paper-button:disabled { opacity: 0.42; }

.modal-backdrop { position: fixed; inset: 0; z-index: 1400; display: flex; align-items: center; justify-content: center; padding: 1rem; background: rgba(24, 18, 14, 0.72); }
.preview-card, .confirm-card { width: min(19rem, 90vw); max-height: 30rem; padding: 0.7rem; background: $paper; box-shadow: 0 12px 30px rgba(0, 0, 0, 0.4); }
.preview-card img { width: 100%; max-height: 25rem; object-fit: contain; background: #171513; }
.preview-card > button { width: 100%; margin-top: 0.5rem; padding: 0.45rem; border: 0; color: white; background: $ink; }
.preview-loading { min-height: 15rem; display: flex; align-items: center; justify-content: center; }
.confirm-card h2 { margin: 0 0 0.45rem; font-size: 1.1rem; }
.confirm-card p { color: $muted; font-size: 0.72rem; line-height: 1.35; }
.confirm-card > div { display: flex; justify-content: flex-end; gap: 0.4rem; }

@keyframes spin { to { transform: rotate(360deg); } }
</style>
