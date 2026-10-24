<template>
  <!-- Controller: B / Start unwind (photo -> location -> close), LB / RB turn the map pages. Without the
       .asMouse modifier: that turns the handler into a synthetic click on <main>, so B did nothing. -->
  <main
    class="journal-screen"
    bng-ui-scope="travelJournalFullscreen"
    v-bng-ui-nav-scroll
    v-bng-on-ui-nav:back,menu="handleBack"
    v-bng-on-ui-nav:tab_l="pageLeft"
    v-bng-on-ui-nav:tab_r="pageRight">
    <div class="journal-book">
      <div v-if="loading" class="center-state"><span class="spinner"></span><span>Opening journal...</span></div>
      <div v-else-if="error" class="center-state error-state">
        <strong>Journal unavailable</strong><span>{{ error }}</span>
        <button bng-nav-item class="paper-button primary retry-button" @click="loadState">Try again</button>
        <button bng-nav-item class="paper-button" @click="closeJournal">Close</button>
      </div>

      <template v-else-if="selectedMap">
        <header class="book-header">
          <button bng-nav-item class="paper-button close-button" @click="closeJournal">Close Journal</button>
          <div class="map-heading">
            <span class="eyebrow">Travel Journal</span>
            <div class="map-title-row">
              <button bng-nav-item class="page-arrow" :disabled="mapIndex === 0" :bng-no-nav="mapIndex === 0 ? 'true' : null" aria-label="Previous map" @click="previousMap">&#8249;<BngBinding v-if="maps.length > 1" class="page-glyph" ui-event="tab_l" controller track-ignore /></button>
              <div><h1>{{ selectedMap.name }}</h1><p>{{ selectedMap.completedCount }} / {{ selectedMap.totalCount }} locations complete</p></div>
              <button bng-nav-item class="page-arrow" :disabled="mapIndex >= maps.length - 1" :bng-no-nav="mapIndex >= maps.length - 1 ? 'true' : null" aria-label="Next map" @click="nextMap">&#8250;<BngBinding v-if="maps.length > 1" class="page-glyph" ui-event="tab_r" controller track-ignore /></button>
            </div>
          </div>
          <div class="xp-note"><b>1,000 XP</b><span>per first completion</span></div>
        </header>

        <section class="location-layout" aria-label="Journal locations">
          <button
            v-for="(location, index) in selectedMap.locations"
            :key="location.id"
            bng-nav-item
            class="location-card"
            :class="[`slot-${index + 1}`, location.status]"
            :data-location="location.id"
            @click="openLocation(location)"
          >
            <span class="polaroid"><span class="photo-window">
              <img v-if="cardImage(selectedMap, location)" :src="cardImage(selectedMap, location)" :alt="`${location.name} journal cover`" />
              <TravelJournalScenePlaceholder v-else class="memory-placeholder" :status="location.status" />
            </span></span>
            <span class="location-copy">
              <span class="number">No. {{ String(index + 1).padStart(2, '0') }}</span>
              <strong>{{ location.name }}</strong>
              <small class="location-summary" :class="{ hint: location.status === 'notFound' }">{{ cardSummary(location) }}</small>
            </span>
            <span class="status-mark">{{ location.status === 'completed' ? '✓' : location.status === 'discovered' ? 'FOUND' : '?' }}</span>
          </button>

          <div class="map-stamp" :class="{ earned: selectedMap.stampAwarded }">
            <span class="stamp-ring"><b>{{ selectedMap.stampAwarded ? 'COMPLETE' : 'LOCKED' }}</b><small>{{ selectedMap.stampLabel }}</small></span>
            <p>{{ selectedMap.stampAwarded ? 'Map completion stamp earned' : 'Complete all five locations' }}</p>
          </div>
        </section>

        <div class="page-dots" aria-label="Map pages">
          <button v-for="(map, index) in maps" :key="map.id" bng-nav-item :class="{ active: index === mapIndex }" :aria-label="map.name" @click="mapIndex = index"></button>
        </div>
      </template>
    </div>

    <div v-if="selectedLocation" class="detail-backdrop" @click.self="closeLocation">
      <section class="location-detail" v-bng-ui-nav-scroll>
        <header>
          <div><span class="eyebrow">{{ selectedMap.name }}</span><h2>{{ selectedLocation.name }}</h2><p>{{ statusLabel(selectedLocation.status) }}</p></div>
          <button bng-nav-item class="paper-button back-to-page" @click="closeLocation"><BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Back to Page</button>
        </header>
        <p class="location-description">{{ selectedLocation.description }}</p>
        <div class="location-actions">
          <button bng-nav-item class="paper-button primary detail-action" :disabled="routePending || !selectedLocation.canNavigate" :bng-no-nav="(routePending || !selectedLocation.canNavigate) ? 'true' : null" @click="setRoute">
            {{ routePending ? 'Setting Route...' : routedLocationId === selectedLocation.id ? 'Route Selected' : 'Set Route' }}
          </button>
          <button bng-nav-item class="paper-button scene detail-action" :disabled="scenePending || !selectedLocation.canEnterScene" :bng-no-nav="(scenePending || !selectedLocation.canEnterScene) ? 'true' : null" @click="enterPhotoScene">
            {{ scenePending ? 'Opening Photo Mode...' : selectedLocation.insideZone ? 'Enter Photo Scene' : 'Drive Into Scenic Area' }}
          </button>
        </div>
        <p v-if="actionFeedback" class="action-feedback" :class="{ error: actionFeedbackError }">{{ actionFeedback }}</p>

        <div class="section-title"><span>Featured photographs</span><small>3 scrapbook slots</small></div>
        <div class="featured-grid">
          <button v-for="slot in 3" :key="slot" bng-nav-item class="featured-photo" :data-photo="featuredPhotos[slot - 1]?.id" :disabled="!featuredPhotos[slot - 1]" :bng-no-nav="!featuredPhotos[slot - 1] ? 'true' : null" @click="openPreview(featuredPhotos[slot - 1])">
            <img v-if="featuredPhotos[slot - 1] && photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" :src="photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" alt="Featured photograph" />
            <span v-else>Photo {{ slot }}</span>
          </button>
        </div>

        <div class="section-title"><span>Album</span><small>{{ selectedLocation.photoCount }} photos</small></div>
        <div v-if="selectedLocation.photos.length" class="album-grid">
          <button v-for="photo in selectedLocation.photos" :key="photo.id" bng-nav-item class="album-photo" :data-photo="photo.id" @click="openPreview(photo)">
            <img v-if="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" :src="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" alt="Journal photograph" />
            <span v-else class="spinner small"></span><span v-if="photo.cover" class="cover-label">Cover</span>
          </button>
        </div>
        <div v-else class="empty-album">Take a photograph during this location's scene to add it here.</div>
      </section>
    </div>

    <div v-if="previewPhoto" class="preview-backdrop" @click.self="closePreview">
      <div class="preview-card">
        <img v-if="previewUrl" :src="previewUrl" alt="Journal photograph preview" /><span v-else class="spinner"></span>
        <button bng-nav-item class="paper-button close-photo" @click="closePreview"><BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Close Photo</button>
      </div>
    </div>
  </main>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"
import TravelJournalScenePlaceholder from "../components/TravelJournalScenePlaceholder.vue"

import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { runRaw, serialize } from '@/bridge/libs/Lua'
import { useEvents } from '@/services/events'
import { vBngOnUiNav, vBngUiNavScroll } from '@/common/directives'
import { BngBinding } from '@/common/components/base'
import { useUINavScope } from '@/services/uiNav'
import { refocusIfLost } from '../composables/useScreenEntryFocus'
import { acquireScope } from '../utils/luaScopes'

useUINavScope('travelJournalFullscreen')

const events = useEvents()
const state = ref(null)
const loading = ref(true)
const error = ref('')
const mapIndex = ref(0)
const selectedLocationId = ref(null)
const previewPhoto = ref(null)
const routePending = ref(false)
const scenePending = ref(false)
const routedLocationId = ref(null)
const actionFeedback = ref('')
const actionFeedbackError = ref(false)
const photoUrls = reactive({})
const photoRequests = new Set()
const MAX_PHOTO_CACHE_ENTRIES = 48
const callJournal = (method, ...args) => runRaw(`overhaul_phone_travelJournal.${method}(${args.map(serialize).join(',')})`)

function normalizeJournalState(raw) {
  if (!raw || typeof raw !== 'object') return raw
  return {...raw, maps: Array.isArray(raw.maps) ? raw.maps.map(map => ({...map, locations: Array.isArray(map.locations) ? map.locations.map(location => ({...location, photos: Array.isArray(location.photos) ? location.photos : [], featuredPhotoIds: Array.isArray(location.featuredPhotoIds) ? location.featuredPhotoIds : []})) : []})) : []}
}

const maps = computed(() => Array.isArray(state.value?.maps) ? state.value.maps : [])
const selectedMap = computed(() => maps.value[mapIndex.value] || null)
const selectedLocation = computed(() => selectedMap.value?.locations.find(location => location.id === selectedLocationId.value) || null)
const featuredPhotos = computed(() => selectedLocation.value ? selectedLocation.value.featuredPhotoIds.map(id => selectedLocation.value.photos.find(photo => photo.id === id)).filter(Boolean) : [])
const previewUrl = computed(() => previewPhoto.value && selectedMap.value && selectedLocation.value ? photoUrl(selectedMap.value.id, selectedLocation.value.id, previewPhoto.value.id) : null)
const photoKey = (mapId, locationId, photoId) => `${mapId}/${locationId}/${photoId}`

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
  } catch (_) { reportUiFailure(_, "load photo (TravelJournal)") } finally { photoRequests.delete(key) }
}

function queueVisiblePhotos() {
  if (!selectedMap.value) return
  for (const location of selectedMap.value.locations) if (location.coverPhotoId) loadPhoto(selectedMap.value.id, location.id, location.coverPhotoId)
  if (selectedLocation.value) for (const photo of selectedLocation.value.photos) loadPhoto(selectedMap.value.id, selectedLocation.value.id, photo.id)
}

async function loadState() {
  loading.value = true; error.value = ''
  try {
    await acquireScope(lua, 'phone.travelJournal')
    state.value = normalizeJournalState(await callJournal('getJournalState'))
    const currentIndex = maps.value.findIndex(map => map.current)
    if (currentIndex >= 0) mapIndex.value = currentIndex
    queueVisiblePhotos()
  } catch (err) {
    reportUiFailure(err, "[TravelJournal] full journal load failed (TravelJournal)")
    error.value = 'The career journal service could not be loaded.'
  } finally { loading.value = false }
}

function applyState(next) {
  if (!next || typeof next !== 'object') return
  const mapId = selectedMap.value?.id
  state.value = normalizeJournalState(next)
  const nextIndex = mapId ? maps.value.findIndex(map => map.id === mapId) : -1
  if (nextIndex >= 0) mapIndex.value = nextIndex
  if (selectedLocationId.value && !selectedLocation.value) selectedLocationId.value = null
  queueVisiblePhotos()
}

function cardImage(map, location) { return location.status === 'completed' && location.coverPhotoId ? photoUrl(map.id, location.id, location.coverPhotoId) : null }
function statusLabel(status) { return status === 'completed' ? 'Completed' : status === 'discovered' ? 'Discovered' : 'Not found' }
// the card's one line under the name: where to look until found, then what is left to do
function cardSummary(location) {
  if (location.status === 'notFound') return location.description || 'Not found yet'
  if (location.status === 'discovered') return 'Found. Take a photo here to complete it.'
  return `${location.photoCount} photo${location.photoCount === 1 ? '' : 's'} in the album`
}
function previousMap() { if (mapIndex.value > 0) mapIndex.value -= 1 }
function nextMap() { if (mapIndex.value < maps.value.length - 1) mapIndex.value += 1 }
function openLocation(location) { selectedLocationId.value = location.id; actionFeedback.value = ''; actionFeedbackError.value = false; queueVisiblePhotos() }
function closeLocation() { selectedLocationId.value = null; previewPhoto.value = null; actionFeedback.value = '' }

async function setRoute() {
  if (!selectedMap.value || !selectedLocation.value || routePending.value) return
  routePending.value = true; actionFeedback.value = ''; actionFeedbackError.value = false
  try {
    const result = await callJournal('setRouteToLocation', selectedMap.value.id, selectedLocation.value.id)
    if (result?.success) { routedLocationId.value = selectedLocation.value.id; actionFeedback.value = `Navigation is guiding you to ${selectedLocation.value.name}.` }
    else { actionFeedback.value = result?.reason === 'wrong_map' ? `Load ${selectedMap.value.name} to set this route.` : 'Navigation is unavailable.'; actionFeedbackError.value = true }
  } catch (_) { actionFeedback.value = 'Navigation is unavailable.'; actionFeedbackError.value = true } finally { routePending.value = false }
}

async function enterPhotoScene() {
  if (!selectedMap.value || !selectedLocation.value || scenePending.value) return
  scenePending.value = true; actionFeedback.value = ''; actionFeedbackError.value = false
  try {
    const result = await callJournal('requestSceneFromJournal', selectedMap.value.id, selectedLocation.value.id)
    if (!result?.success) {
      actionFeedback.value = result?.reason === 'outside_zone' ? 'Drive into the scenic area first.' : result?.reason === 'trailer_attached' ? 'Detach the trailer before entering.' : 'The photography scene could not be opened.'
      actionFeedbackError.value = true; scenePending.value = false
    }
  } catch (_) { actionFeedback.value = 'The photography scene could not be opened.'; actionFeedbackError.value = true; scenePending.value = false }
}

function openPreview(photo) { if (photo) previewPhoto.value = photo }
function closePreview() { previewPhoto.value = null }
function handleBack() { if (previewPhoto.value) return closePreview(); if (selectedLocation.value) return closeLocation(); closeJournal() }
// LB / RB turn the map pages while the page itself is showing
function pageLeft() { if (!selectedLocation.value && !previewPhoto.value) previousMap() }
function pageRight() { if (!selectedLocation.value && !previewPhoto.value) nextMap() }

// ---- controller focus: the screen has no scoped-nav scope, so it places focus itself
const journalEl = () => document.querySelector('.journal-screen')
const pickPageFocus = () =>
  journalEl()?.querySelector('.location-card')
  || journalEl()?.querySelector('.retry-button')
  || journalEl()?.querySelector('.close-button')
const pickDetailFocus = () =>
  journalEl()?.querySelector('.location-detail .detail-action:not(:disabled)')
  || journalEl()?.querySelector('.location-detail .back-to-page')
// entry, and after a page turn replaced the cards
watch(loading, isLoading => { if (!isLoading) refocusIfLost(pickPageFocus) }, { flush: 'post' })
watch(mapIndex, () => refocusIfLost(pickPageFocus), { flush: 'post' })
// location detail: land on its first action, return to the card that opened it
watch(selectedLocationId, (id, prevId) => {
  if (id) refocusIfLost(pickDetailFocus, { force: true })
  else if (prevId) refocusIfLost(() => journalEl()?.querySelector(`.location-card[data-location="${prevId}"]`) || pickPageFocus(), { force: true })
}, { flush: 'post' })
// photo preview: Close Photo, then back to the photo that opened it
watch(previewPhoto, (photo, prevPhoto) => {
  if (photo) refocusIfLost(() => journalEl()?.querySelector('.close-photo'), { force: true })
  else if (prevPhoto && selectedLocationId.value) refocusIfLost(() => journalEl()?.querySelector(`.location-detail [data-photo="${prevPhoto.id}"]`) || pickDetailFocus(), { force: true })
}, { flush: 'post' })
// Set Route / Enter Photo Scene disable while pending, which drops focus
watch([routePending, scenePending], () => refocusIfLost(pickDetailFocus), { flush: 'post' })
function closeJournal() { runRaw('extensions.ui_router.navigate("play")') }

watch([mapIndex, selectedLocationId], queueVisiblePhotos)
onMounted(() => { events.on('TravelJournalStateChanged', applyState); loadState() })
onBeforeUnmount(() => events.off('TravelJournalStateChanged', applyState))
</script>

<style scoped lang="scss">
$ink: #342a25; $muted: #786a61; $rose: #a95e62; $green: #55735b;
// The book is a flex column at least one screen tall (minus the padding); the location grid takes what is left
// under the header, so it never overflows by a fixed guess of the header height (it did at 720p).
// --rls-u: scaled unit so the book keeps the same share of the screen at 720p..4K (rem-sized it overflowed at
// 720p and shrank at 1440p), still following the player's UI scale
.journal-screen { --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem); position: fixed; inset: 0; z-index: 100; box-sizing: border-box; overflow: auto; padding: clamp(var(--rls-u, 1rem), 2vw, calc(2 * var(--rls-u, 1rem))); color: $ink; background: rgba(17, 14, 12, 0.88); font-family: Georgia, 'Times New Roman', serif; }
.journal-book { display: flex; flex-direction: column; width: min(calc(112 * var(--rls-u, 1rem)), 100%); min-height: calc(100vh - clamp(calc(2 * var(--rls-u, 1rem)), 4vw, calc(4 * var(--rls-u, 1rem)))); margin: auto; box-sizing: border-box; overflow: hidden; border: calc(0.8 * var(--rls-u, 1rem)) solid #70533f; border-radius: calc(0.8 * var(--rls-u, 1rem)); background: radial-gradient(circle at 17% 20%, rgba(121,84,54,.1) 0 1px, transparent 1.6px), linear-gradient(100deg, #f4ecde 0 49.7%, #d7c9b4 49.8% 50.2%, #f1e7d7 50.3%); background-size: 25px 28px, auto; box-shadow: 0 calc(1.2 * var(--rls-u, 1rem)) calc(3 * var(--rls-u, 1rem)) rgba(0,0,0,.55), inset 0 0 calc(5 * var(--rls-u, 1rem)) rgba(88,59,38,.12); }
.book-header { display: grid; grid-template-columns: minmax(calc(10 * var(--rls-u, 1rem)),1fr) minmax(calc(24 * var(--rls-u, 1rem)),2fr) minmax(calc(10 * var(--rls-u, 1rem)),1fr); align-items: center; gap: var(--rls-u, 1rem); padding: calc(1.2 * var(--rls-u, 1rem)) calc(1.5 * var(--rls-u, 1rem)) calc(.7 * var(--rls-u, 1rem)); border-bottom: 1px dashed rgba(69,48,34,.28); }
.map-heading { text-align: center; }.map-title-row { display: grid; grid-template-columns: calc(3 * var(--rls-u, 1rem)) 1fr calc(3 * var(--rls-u, 1rem)); align-items: center; gap: calc(.8 * var(--rls-u, 1rem)); }.map-heading h1 { margin: calc(.1 * var(--rls-u, 1rem)) 0 0; font-size: clamp(calc(2 * var(--rls-u, 1rem)),3.1vw,calc(3.7 * var(--rls-u, 1rem))); line-height: .95; }.map-heading p { margin: calc(.3 * var(--rls-u, 1rem)) 0 0; color: $muted; font: calc(.9 * var(--rls-u, 1rem)) Arial,sans-serif; }
.eyebrow { color: $rose; font: 700 calc(.72 * var(--rls-u, 1rem)) Arial,sans-serif; letter-spacing: .16em; text-transform: uppercase; }.page-arrow { width: calc(2.7 * var(--rls-u, 1rem)); height: calc(2.7 * var(--rls-u, 1rem)); border: 0; border-radius: 50%; color: $ink; background: rgba(105,75,54,.1); font-size: calc(2 * var(--rls-u, 1rem)); }.page-arrow:disabled { opacity: .2; }
.paper-button { min-height: calc(2.6 * var(--rls-u, 1rem)); padding: calc(.55 * var(--rls-u, 1rem)) calc(.9 * var(--rls-u, 1rem)); border: 1px solid rgba(78,58,45,.3); border-radius: calc(.3 * var(--rls-u, 1rem)); color: $ink; background: #f8f1e3; box-shadow: 0 2px 5px rgba(53,38,27,.15); font: 700 calc(.78 * var(--rls-u, 1rem)) Arial,sans-serif; }.paper-button.primary { color: #fff; border-color: $rose; background: $rose; }.paper-button.scene { color: #fff; border-color: $green; background: $green; }.paper-button:disabled { opacity: .4; }.xp-note { justify-self: end; display: flex; flex-direction: column; padding: calc(.6 * var(--rls-u, 1rem)) calc(.85 * var(--rls-u, 1rem)); color: $green; border: 2px solid $green; transform: rotate(3deg); text-align: center; }.xp-note b { font: 800 var(--rls-u, 1rem) Arial,sans-serif; }.xp-note span { color: $muted; font: calc(.66 * var(--rls-u, 1rem)) Arial,sans-serif; }
.location-layout { display: grid; grid-template-columns: repeat(3,minmax(calc(17 * var(--rls-u, 1rem)),1fr)); grid-template-rows: repeat(2,minmax(calc(15 * var(--rls-u, 1rem)),1fr)); grid-template-areas: 'one two three' 'four stamp five'; align-items: center; gap: clamp(calc(.8 * var(--rls-u, 1rem)),1.5vw,calc(1.5 * var(--rls-u, 1rem))); flex: 1 1 auto; min-height: 0; padding: calc(1.2 * var(--rls-u, 1rem)) calc(2 * var(--rls-u, 1rem)); }
.location-card { position: relative; display: grid; grid-template-columns: minmax(calc(8 * var(--rls-u, 1rem)),44%) 1fr; align-items: center; gap: calc(.9 * var(--rls-u, 1rem)); width: 100%; min-height: calc(12.5 * var(--rls-u, 1rem)); box-sizing: border-box; padding: calc(.75 * var(--rls-u, 1rem)) calc(.9 * var(--rls-u, 1rem)); border: 0; color: $ink; background: rgba(255,251,242,.96); box-shadow: 0 calc(.55 * var(--rls-u, 1rem)) var(--rls-u, 1rem) rgba(55,37,24,.22); text-align: left; transition: transform .13s,box-shadow .13s; }.location-card:hover,.location-card.focus-visible { z-index: 2; box-shadow: 0 calc(.8 * var(--rls-u, 1rem)) calc(1.5 * var(--rls-u, 1rem)) rgba(55,37,24,.34); transform: rotate(0) scale(1.025); outline: 3px solid rgba(169,94,98,.55); }.slot-1{grid-area:one;transform:rotate(-1.4deg)}.slot-2{grid-area:two;transform:rotate(.8deg)}.slot-3{grid-area:three;transform:rotate(-.7deg)}.slot-4{grid-area:four;transform:rotate(.9deg)}.slot-5{grid-area:five;transform:rotate(-1.1deg)}
.polaroid { display:block; padding:calc(.45 * var(--rls-u, 1rem)) calc(.45 * var(--rls-u, 1rem)) calc(1.1 * var(--rls-u, 1rem)); background:#fff; box-shadow:0 calc(.25 * var(--rls-u, 1rem)) calc(.6 * var(--rls-u, 1rem)) rgba(38,28,21,.24) }.photo-window { display:block; height:clamp(calc(7.5 * var(--rls-u, 1rem)),15vh,calc(11 * var(--rls-u, 1rem))); overflow:hidden; background:#cfc4b2 }.photo-window img { width:100%; height:100%; display:block; object-fit:cover }.memory-placeholder { font-size:calc(.68 * var(--rls-u, 1rem)) }
.location-copy { min-width:0; display:flex; flex-direction:column; gap:calc(.35 * var(--rls-u, 1rem)) }.location-copy strong { font-size:clamp(calc(1.05 * var(--rls-u, 1rem)),1.4vw,calc(1.45 * var(--rls-u, 1rem))); line-height:1.05 }.location-copy small { color:$muted; font:calc(.72 * var(--rls-u, 1rem))/1.3 Arial,sans-serif }.location-copy .location-summary { display:-webkit-box; overflow:hidden; -webkit-box-orient:vertical; -webkit-line-clamp:3; color:#5f5249; font-size:calc(.8 * var(--rls-u, 1rem)) }.location-copy .location-summary.hint { font-style:italic; font-family:Georgia,'Times New Roman',serif }.number { color:$rose; font:700 calc(.67 * var(--rls-u, 1rem)) Arial,sans-serif; letter-spacing:.1em; text-transform:uppercase }.status-mark { position:absolute; right:calc(.75 * var(--rls-u, 1rem)); bottom:calc(.65 * var(--rls-u, 1rem)); min-width:calc(2 * var(--rls-u, 1rem)); height:calc(2 * var(--rls-u, 1rem)); display:flex; align-items:center; justify-content:center; border:2px solid rgba(86,62,46,.35); border-radius:50%; color:$muted; font:700 calc(.55 * var(--rls-u, 1rem)) Arial,sans-serif; transform:rotate(-8deg) }.location-card.completed .status-mark { color:$green; border-color:$green; font-size:calc(1.1 * var(--rls-u, 1rem)) }.location-card.discovered .status-mark { color:#a47738; border-color:#a47738 }
.map-stamp { grid-area:stamp; justify-self:center; display:flex; flex-direction:column; align-items:center; gap:calc(.5 * var(--rls-u, 1rem)); opacity:.48; text-align:center }.map-stamp.earned{opacity:1}.stamp-ring { width:calc(8.5 * var(--rls-u, 1rem)); height:calc(8.5 * var(--rls-u, 1rem)); display:flex; flex-direction:column; align-items:center; justify-content:center; border:5px double $rose; border-radius:50%; color:$rose; transform:rotate(-8deg) }.stamp-ring b { font:800 calc(.95 * var(--rls-u, 1rem)) Arial,sans-serif; letter-spacing:.12em }.stamp-ring small { max-width:calc(7 * var(--rls-u, 1rem)); font-size:calc(.7 * var(--rls-u, 1rem)) }.map-stamp p { margin:0; color:$muted; font:calc(.72 * var(--rls-u, 1rem)) Arial,sans-serif }.page-dots { display:flex; justify-content:center; gap:calc(.45 * var(--rls-u, 1rem)); padding:0 0 var(--rls-u, 1rem) }.page-dots button { width:calc(.58 * var(--rls-u, 1rem)); height:calc(.58 * var(--rls-u, 1rem)); padding:0; border:0; border-radius:50%; background:rgba(62,43,32,.25) }.page-dots button.active { background:$rose; transform:scale(1.25) }
.detail-backdrop,.preview-backdrop { position:fixed; inset:0; z-index:1300; display:flex; align-items:center; justify-content:center; padding:calc(2 * var(--rls-u, 1rem)); background:rgba(20,15,12,.72); backdrop-filter:blur(4px) }.location-detail { width:min(calc(76 * var(--rls-u, 1rem)),calc(100vw - calc(4 * var(--rls-u, 1rem)))); max-height:calc(100vh - calc(4 * var(--rls-u, 1rem))); overflow:auto; box-sizing:border-box; padding:calc(1.4 * var(--rls-u, 1rem)); color:$ink; background:linear-gradient(145deg,#f7efe2,#e6d9c5); box-shadow:0 calc(1.2 * var(--rls-u, 1rem)) calc(3 * var(--rls-u, 1rem)) rgba(0,0,0,.5) }.location-detail>header { display:flex; justify-content:space-between; align-items:center; gap:var(--rls-u, 1rem); border-bottom:1px dashed rgba(69,48,34,.28) }.location-detail h2 { margin:calc(.2 * var(--rls-u, 1rem)) 0 0; font-size:calc(2 * var(--rls-u, 1rem)) }.location-detail header p { margin:calc(.2 * var(--rls-u, 1rem)) 0 calc(.8 * var(--rls-u, 1rem)); color:$muted; font:calc(.8 * var(--rls-u, 1rem)) Arial,sans-serif }.location-description { color:$muted; font-size:var(--rls-u, 1rem); line-height:1.45 }.location-actions { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:calc(.7 * var(--rls-u, 1rem)) }.action-feedback { color:$green; font:700 calc(.78 * var(--rls-u, 1rem)) Arial,sans-serif }.action-feedback.error{color:#9f4c4c}.section-title { display:flex; justify-content:space-between; margin:calc(1.15 * var(--rls-u, 1rem)) 0 calc(.55 * var(--rls-u, 1rem)); padding-bottom:calc(.3 * var(--rls-u, 1rem)); border-bottom:1px solid rgba(72,49,34,.2); font-weight:700 }.section-title small{color:$muted;font:calc(.72 * var(--rls-u, 1rem)) Arial,sans-serif}
.featured-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:calc(.8 * var(--rls-u, 1rem)) }.featured-photo { height:calc(12 * var(--rls-u, 1rem)); padding:calc(.5 * var(--rls-u, 1rem)); border:0; color:rgba(79,58,43,.55); background:#fffaf0; box-shadow:0 calc(.25 * var(--rls-u, 1rem)) calc(.65 * var(--rls-u, 1rem)) rgba(50,34,22,.16) }.featured-photo img { width:100%; height:100%; object-fit:cover }.featured-photo:disabled{opacity:.65}.album-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:calc(.8 * var(--rls-u, 1rem)) }.album-photo { position:relative; height:calc(10 * var(--rls-u, 1rem)); padding:calc(.4 * var(--rls-u, 1rem)); border:0; background:#fffaf0; box-shadow:0 calc(.25 * var(--rls-u, 1rem)) calc(.65 * var(--rls-u, 1rem)) rgba(50,34,22,.16) }.album-photo img { width:100%; height:100%; object-fit:cover }.cover-label { position:absolute; left:0; top:calc(.8 * var(--rls-u, 1rem)); padding:calc(.25 * var(--rls-u, 1rem)) calc(.55 * var(--rls-u, 1rem)); color:#fff; background:$rose; font:700 calc(.65 * var(--rls-u, 1rem)) Arial,sans-serif }.empty-album { padding:calc(2.5 * var(--rls-u, 1rem)); color:$muted; border:1px dashed rgba(79,58,43,.3); text-align:center }.preview-card { max-width:min(85vw,calc(80 * var(--rls-u, 1rem))); max-height:calc(100vh - calc(4 * var(--rls-u, 1rem))); display:flex; flex-direction:column; gap:calc(.7 * var(--rls-u, 1rem)); padding:calc(.7 * var(--rls-u, 1rem)); background:#eee5d3 }.preview-card img { max-width:100%; max-height:calc(100vh - calc(8 * var(--rls-u, 1rem))); object-fit:contain; background:#171513 }
.center-state { flex: 1 1 auto; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:calc(.8 * var(--rls-u, 1rem)); color:$muted }.spinner { width:calc(1.8 * var(--rls-u, 1rem)); height:calc(1.8 * var(--rls-u, 1rem)); display:inline-block; border:3px solid rgba(83,66,54,.2); border-top-color:$rose; border-radius:50%; animation:spin .8s linear infinite }.spinner.small{width:var(--rls-u, 1rem);height:var(--rls-u, 1rem);border-width:2px}@keyframes spin{to{transform:rotate(360deg)}}
@media(max-width:74rem){.location-layout{grid-template-columns:repeat(2,minmax(16rem,1fr));grid-template-rows:auto;grid-template-areas:'one two' 'three four' 'stamp five'}.book-header{grid-template-columns:auto 1fr auto}}
@media(max-width:48rem){.journal-screen{padding:0}.journal-book{min-height:100vh;border-width:.35rem;border-radius:0}.book-header{grid-template-columns:1fr;text-align:center}.xp-note{display:none}.location-layout{display:flex;flex-direction:column;min-height:auto;padding:1rem}.location-card{transform:none}.map-stamp{order:6;margin:1rem}.detail-backdrop{padding:.5rem}.location-detail{width:100%;max-height:calc(100vh - 1rem)}.featured-grid,.album-grid,.location-actions{grid-template-columns:1fr}}

/* Controller focus: the house ring (same values as rlsHouse.scss --focus / house-focus) for the game's
   controller class (.focus-visible) as well as :focus-visible, without the game's ::before frame. */
$journal-focus-ring: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600), 0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
@mixin journal-focus {
  position: relative; // anchors the game's absolute frame on the control, never on an ancestor
  &.focus-visible {
    outline: none;
    box-shadow: $journal-focus-ring;
  }
  &.focus-visible::before {
    display: none !important;
  }
}
.paper-button,
.page-arrow,
.page-dots button,
.featured-photo,
.album-photo,
.location-card { @include journal-focus; }
// the picked-up look the card has on hover, for controller focus too (the ring replaces the outline)
.location-card.focus-visible { z-index: 2; transform: rotate(0) scale(1.025); }
.page-glyph { position: absolute; top: calc(100% + calc(0.2 * var(--rls-u, 1rem))); left: 50%; transform: translateX(-50%); font-size: calc(0.8 * var(--rls-u, 1rem)); pointer-events: none; }
.btn-glyph { margin-right: 0.4em; vertical-align: -0.15em; }
</style>
