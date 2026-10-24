<template>
  <Teleport to="body">
    <!-- Idle travel is a gameplay HUD. A remappable action picks it up; only the
         engaged panel/blocked dialog report popup state and claim menu controls. -->
    <div v-if="shown" class="map-travel-layer">
      <section
        ref="panel"
        class="map-travel-panel"
        :class="{ minimized, engaged }"
        :style="panelStyle"
        :bng-no-child-nav="!engaged ? 'true' : null"
        v-bng-scoped-nav="{ ...panelNavScope, activated: engaged && !blocked, activateOnMount: engaged && !blocked }"
      >
        <header class="panel-header">
          <div class="header-drag" @pointerdown="startDrag">
            <h2 class="header-title">Travel</h2>
            <span class="header-pill">{{ summary }}</span>
          </div>
          <div class="header-actions" @pointerdown.stop>
            <!-- Show the bound gameplay action while idle; Back returns to driving. -->
            <span class="pad-hint">
              <BngBinding v-if="!engaged" action="overhaulTravelPanel" controller track-ignore />
              <BngBinding v-else ui-event="back" controller track-ignore />
            </span>
            <button type="button" class="hdr-btn" title="Reset position" aria-label="Reset panel position" @click="resetPosition">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.3-5.7" /><path d="M20 4v6h-6" /></svg>
            </button>
            <button type="button" class="hdr-btn" :title="minimized ? 'Expand panel' : 'Minimize panel'" :aria-label="minimized ? 'Expand panel' : 'Minimize panel'" @click="minimized = !minimized">
              <svg v-if="minimized" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5" /></svg>
              <svg v-else viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12h14" /></svg>
            </button>
          </div>
        </header>

        <div v-if="!minimized" class="panel-content">
          <section class="dest-section">
            <h3 class="section-title">Destination</h3>
            <div v-if="destinationMaps.length" class="map-cards-scroll" v-bng-ui-nav-scroll>
              <div class="map-cards" role="listbox" aria-label="Travel destination">
                <button
                  v-for="map in destinationMaps"
                  :key="map.value"
                  type="button"
                  role="option"
                  class="map-card"
                  :class="{ selected: selectedMap === map.value }"
                  :aria-selected="selectedMap === map.value"
                  :disabled="busy"
                  :bng-no-nav="busy ? 'true' : null"
                  :bng-scoped-nav-autofocus="!canPressTravel && (selectedMap ? selectedMap === map.value : map === destinationMaps[0]) ? '' : null"
                  @click="selectDestination(map.value)"
                >
                  <span class="map-card-art" :style="{ backgroundImage: mapArtBackground(map.preview) }">
                    <span class="map-card-name">{{ map.label }}</span>
                  </span>
                </button>
              </div>
            </div>
            <p v-else class="hint">No other compatible maps installed.</p>

            <p v-if="travelError" class="carrier-error" role="alert">{{ travelError }}</p>
          </section>

          <p v-if="!state.canTravel" class="hint warn">Enter the travel zone first.</p>

          <details v-if="showStaging" class="staging-details">
            <summary class="kicker staging-summary" bng-nav-item>{{ stagingTitle }}</summary>
            <p v-if="carrierError" class="carrier-error" role="alert">{{ carrierError }}</p>
            <div class="staging-scroll fleet-panel" v-bng-ui-nav-scroll>
              <ul v-if="displayVehicles.length" class="staging-list">
                <li
                  v-for="member in displayVehicles"
                  :key="member.inventoryId"
                  class="staging-tile"
                  :class="{
                    assigned: member.current,
                    child: member.displayDepth > 0,
                    'drop-target': dropTargetId === member.inventoryId,
                  }"
                  :style="{ '--depth': member.displayDepth }"
                  :draggable="false"
                  @dragstart.stop="startVehicleDrag($event, member.inventoryId)"
                  @dragover.stop.prevent="dragOverVehicle(member.inventoryId)"
                  @drop.stop.prevent="dropOnVehicle(member.inventoryId)"
                  @dragend="finishVehicleDrag"
                >
                  <div class="tile-main">
                    <div class="tile-head">
                      <strong class="tile-name">{{ member.label }}</strong>
                      <span v-if="member.current || member.carrierSource" class="pills">
                        <span v-if="member.current" class="pill accent">Now</span>
                        <span v-if="member.carrierSource" class="pill soft">{{ member.carrierSource }}</span>
                      </span>
                    </div>
                    <div v-if="!isCarrierParent(member.inventoryId) || member.carrierInventoryId" class="vehicle-tools">
                      <BngDropdown
                        v-if="!isCarrierParent(member.inventoryId)"
                        class="travel-dropdown"
                        :aria-label="`Carry ${member.label} on`"
                        :model-value="Number(member.carrierInventoryId) || null"
                        :items="carrierOptions(member.inventoryId)"
                        :disabled="busy || carrierPending || !carrierOptions(member.inventoryId).length"
                        @update:model-value="assignCarrier(member.inventoryId, $event)"
                      >
                        <template #display>
                          {{ carrierOptions(member.inventoryId).find(carrier => carrier.value === Number(member.carrierInventoryId))?.label || 'Carrier…' }}
                        </template>
                      </BngDropdown>
                      <button
                        v-if="member.carrierInventoryId"
                        type="button"
                        class="btn btn-ghost"
                        :title="member.nearbySelected ? 'Exclude from travel' : 'Travel separately'"
                        :disabled="busy || carrierPending"
                        :bng-no-nav="(busy || carrierPending) ? 'true' : null"
                        draggable="false"
                        @click.stop="clearCarrier(member.inventoryId)"
                      >
                        {{ member.nearbySelected ? 'Remove' : 'Split' }}
                      </button>
                    </div>
                  </div>
                </li>
              </ul>
              <div v-if="state.nearbyVehicles.length" class="nearby-block">
                <div class="nearby-head">
                  <span class="kicker">Nearby · 8 m</span>
                  <button type="button" class="btn btn-ghost" :disabled="busy || carrierPending" :bng-no-nav="(busy || carrierPending) ? 'true' : null" @click="refreshNearby">Refresh</button>
                </div>
                <ul class="staging-list">
                  <li v-for="vehicle in state.nearbyVehicles" :key="vehicle.inventoryId" class="staging-tile nearby">
                    <div class="tile-main">
                      <strong class="tile-name">{{ vehicle.label }}</strong>
                      <div class="vehicle-tools">
                        <button v-if="vehicle.invalidSelection" type="button" class="btn btn-ghost" :disabled="busy || carrierPending" :bng-no-nav="(busy || carrierPending) ? 'true' : null" @click="clearCarrier(vehicle.inventoryId)">Clear</button>
                        <BngDropdown
                          v-else
                          class="travel-dropdown"
                          :items="vehicle.carriers"
                          :model-value="null"
                          :disabled="busy || carrierPending"
                          @update:model-value="assignCarrier(vehicle.inventoryId, $event)"
                        >
                          <template #display>Carrier…</template>
                        </BngDropdown>
                      </div>
                    </div>
                  </li>
                </ul>
              </div>
            </div>
          </details>

          <button
            type="button"
            class="btn btn-primary travel-button"
            :disabled="!canPressTravel"
            :bng-no-nav="!canPressTravel ? 'true' : null"
            :bng-scoped-nav-autofocus="canPressTravel ? '' : null"
            @click="confirmTravel"
          >
            {{ busy ? 'Preparing travel…' : 'Travel' }}
          </button>
        </div>
      </section>

      <div v-if="blocked" class="travel-modal-backdrop" @pointerdown.self="dismissBlocked">
        <section
          class="map-travel-panel travel-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="travel-blocked-title"
          v-bng-scoped-nav="blockedNavScope">
          <header class="panel-header">
            <div class="header-drag static">
              <h2 id="travel-blocked-title" class="header-title">Travel blocked</h2>
              <span class="header-pill">{{ blockedItems.length }} open</span>
            </div>
            <div class="header-actions">
              <button type="button" class="hdr-btn" title="Cancel travel" aria-label="Cancel travel" :disabled="resolving" :bng-no-nav="resolving ? 'true' : null" @click="dismissBlocked">
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
              </button>
            </div>
          </header>
          <div class="panel-content modal-content">
            <p class="hint">Broker work and rented equipment must be settled before leaving for {{ blockedDestination }}.</p>
            <p v-if="blocked.message" class="carrier-error" role="alert">{{ blocked.message }}</p>
            <!-- read-only list (focus stays on the buttons): the right stick scrolls it -->
            <ul class="modal-list" v-bng-ui-nav-scroll.force>
              <li v-for="item in blockedItems" :key="item.key" class="modal-row">
                <div class="tile-main">
                  <div class="tile-head">
                    <strong class="tile-name">{{ item.label }}</strong>
                    <span class="pills">
                      <span class="pill" :class="item.pillClass">{{ item.action }}</span>
                      <span v-if="item.fine" class="pill fine">-<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(item.fine) }}</span>
                    </span>
                  </div>
                  <small class="tile-sub">{{ item.detail }}</small>
                </div>
              </li>
            </ul>
            <div class="modal-total">
              <span>Penalty if you leave now</span>
              <strong :class="{ fine: blockedFine > 0 }"><template v-if="blockedFine > 0">-<BngIcon class="cur" :type="icons.beamCurrency" />{{ money(blockedFine) }}</template><template v-else>None</template></strong>
            </div>
            <div class="modal-actions">
              <button type="button" class="btn btn-ghost" :disabled="resolving" :bng-no-nav="resolving ? 'true' : null" bng-scoped-nav-autofocus @click="dismissBlocked"><BngBinding class="btn-glyph" ui-event="back" controller track-ignore />Cancel travel</button>
              <button type="button" class="btn btn-primary" :disabled="resolving" :bng-no-nav="resolving ? 'true' : null" @click="resolveAndTravel">
                {{ resolving ? 'Settling…' : 'Return all and travel' }}
              </button>
            </div>
          </div>
        </section>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { reportPopupState } from "@/services/stateReporter.js"
import { safeLua, reportUiFailure } from "../utils/safeLua.js"

import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { BngBinding, BngDropdown, BngIcon, icons } from '@/common/components/base'
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from '@/common/directives'
import { lua, useBridge } from '@/bridge'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
import { loadMapCatalog } from '../profiles/components/start/useStartMaps.js'

const storageKey = 'rls-map-travel-panel-position'
const route = useRoute()
const bridge = useBridge()
const panel = ref(null)
const minimized = ref(false)
const selectedMap = ref(null)
const travelError = ref('')
const mapOptions = ref([])
const busy = ref(false)
const carrierPending = ref(false)
const carrierError = ref('')
const blocked = ref(null)
const resolving = ref(false)
const position = reactive({ x: 0, y: 0, ready: false })
const state = reactive({
  visible: false,
  walkingInside: false,
  canTravel: false,
  switching: false,
  vehicleCount: 0,
  groupCount: 0,
  groups: [],
  vehicles: [],
  nearbyVehicles: [],
})

let dragState = null
const draggedVehicleId = ref(null)
const dropTargetId = ref(null)
let resizeObserver = null
let panelMounted = false
const handleWindowResize = () => clampPosition(true)

const shown = computed(() => state.visible && (route.name === 'play' || !route.name))
const mapCatalog = ref([])

const summary = computed(() => {
  if (state.vehicleCount === 0) return state.walkingInside ? 'On foot' : 'Ready'
  return `${state.vehicleCount} vehicle${state.vehicleCount === 1 ? '' : 's'}`
})
const destinationMaps = computed(() =>
  mapOptions.value.map(item => ({
    ...item,
    preview: mapPreviewFor(item.value),
  })),
)
const showStaging = computed(() =>
  displayVehicles.value.length > 0 || state.nearbyVehicles.length > 0,
)
const stagingTitle = computed(() => `Staging · ${state.vehicleCount || 0}`)

const blockedDestination = computed(() => {
  const id = blocked.value?.destination
  return mapOptions.value.find(item => item.value === id)?.label || id || 'another map'
})
const blockedItems = computed(() => {
  const data = blocked.value?.blockers || {}
  const jobs = (Array.isArray(data.jobs) ? data.jobs : Object.values(data.jobs || {})).map(job => ({
    key: `job:${job.id}`,
    label: job.title || `${job.kind || 'Broker'} load`,
    detail: job.from && job.to ? `${job.from} → ${job.to}` : 'Broker load',
    pillClass: job.status === 'active' ? 'accent' : '',
    action: job.status === 'active' ? 'Abandon' : 'Cancel',
    fine: Number(job.fine) || 0,
  }))
  const rentals = (Array.isArray(data.rentals) ? data.rentals : Object.values(data.rentals || {})).map(rental => ({
    key: `rental:${rental.id}`,
    label: rental.name || 'Rented equipment',
    detail: rental.collected ? 'Rented equipment' : 'Equipment booking',
    pillClass: rental.collected ? 'accent' : '',
    action: rental.collected ? 'Return' : 'Cancel',
    fine: 0,
  }))
  return [...jobs, ...rentals]
})
const blockedFine = computed(() => Number(blocked.value?.blockers?.totalFine) || 0)
const canPressTravel = computed(() => !busy.value && !carrierPending.value && state.canTravel && !!selectedMap.value)

// ---- controller (see the template comment): Y picks the panel up, B puts it down
const engaged = ref(false)
const engage = () => {
  if (!shown.value || blocked.value) return
  minimized.value = false
  engaged.value = true
}
const disengage = () => {
  engaged.value = false
  // leave nothing focused in the panel, so the d-pad goes back to the car
  if (panel.value?.contains(document.activeElement)) document.activeElement.blur()
}
const travelPopup = { componentName: 'overhaul-map-travel', wrapper: { blur: false } }
const ownsMenu = computed(() => shown.value && (engaged.value || !!blocked.value))
watch(ownsMenu, opened => reportPopupState(travelPopup, opened), { flush: 'sync' })
const panelNavScope = {
  type: 'container',
  trapPolicy: 'always',
  preferAutoFocus: true,
  preventNavigationEscape: ['top', 'bottom', 'left', 'right'],
  // Start still opens the pause menu (a canBubbleEvent filter here would also cut off crossfire's A / d-pad)
  bubbleWhitelistEvents: ['menu'],
  canDeactivate: () => {
    disengage()
    return false
  },
}
const blockedNavScope = {
  type: 'container',
  activateOnMount: true,
  trapPolicy: 'always',
  preferAutoFocus: true,
  preventNavigationEscape: ['top', 'bottom', 'left', 'right'],
  canDeactivate: () => {
    dismissBlocked()
    return false
  },
}
// Template puts the game currency glyph before it.
const money = value => Math.max(0, Math.round(Number(value) || 0)).toLocaleString()

function onTravelBlocked(payload) {
  const data = normalizePayload(payload)
  blocked.value = { destination: data.destination,
    blockers: data.blockers || {}, message: data.message || '' }
  resolving.value = false
  busy.value = false
}

function onTravelUnavailable(payload) {
  const data = normalizePayload(payload)
  if (data.destination !== selectedMap.value) return
  travelError.value = data.message || 'The destination could not be prepared.'
  busy.value = false
  resolving.value = false
}

function dismissBlocked() {
  if (resolving.value) return
  blocked.value = null
}

async function resolveAndTravel() {
  if (resolving.value || !blocked.value) return
  const destination = blocked.value.destination || selectedMap.value
  resolving.value = true
  try {
    const accepted = await callModLua('overhaul_career_garage_switchMap.resolveTravelBlockers', destination)
    if (accepted !== true) resolving.value = false
  } catch (_) {
    resolving.value = false
  }
}

async function showTravelBlockersIfAny(destination, message = '') {
  const blockers = await callModLua('overhaul_career_garage_switchMap.getTravelBlockers')
  const count = Number(blockers?.count) || 0
  if (count > 0) {
    onTravelBlocked({ destination, blockers, message })
    return true
  }
  return false
}

function mapArtBackground(preview) {
  const neutral = 'linear-gradient(135deg, #182435, #0b0f19)'
  return preview ? `url("${encodeURI(preview).replace(/"/g, '%22')}"), ${neutral}` : neutral
}

function mapPreviewFor(mapId) {
  const metadata = mapCatalog.value.find(map => map.id === mapId)
  return metadata?.travelPreview || metadata?.preview || null
}
const panelStyle = computed(() => ({
  transform: `translate3d(${position.x}px, ${position.y}px, 0)`,
  visibility: position.ready ? 'visible' : 'hidden',
}))
const displayVehicles = computed(() => {
  const vehicles = state.vehicles.map(vehicle => ({ ...vehicle }))
  const byId = new Map(vehicles.map(vehicle => [Number(vehicle.inventoryId), vehicle]))
  const children = new Map()
  const roots = []
  const sortRows = (a, b) => Number(a.order || 0) - Number(b.order || 0)
    || String(a.label || '').localeCompare(String(b.label || ''))

  for (const vehicle of vehicles) {
    vehicle.inventoryId = Number(vehicle.inventoryId)
    const parentId = Number(vehicle.carrierInventoryId || vehicle.coupledParentInventoryId)
    if (parentId && parentId !== vehicle.inventoryId && byId.has(parentId)) {
      if (!children.has(parentId)) children.set(parentId, [])
      children.get(parentId).push(vehicle)
    } else {
      roots.push(vehicle)
    }
  }
  roots.sort(sortRows)
  for (const rows of children.values()) rows.sort(sortRows)

  const result = []
  const visited = new Set()
  const append = (vehicle, depth) => {
    if (visited.has(vehicle.inventoryId)) return
    visited.add(vehicle.inventoryId)
    result.push({ ...vehicle, displayDepth: depth })
    for (const child of children.get(vehicle.inventoryId) || []) append(child, depth + 1)
  }
  for (const root of roots) append(root, 0)
  for (const vehicle of vehicles.sort(sortRows)) append(vehicle, 0)
  return result
})

function normalizePayload(payload) {
  if (Array.isArray(payload)) return payload.find(item => item && typeof item === 'object') || {}
  return payload && typeof payload === 'object' ? payload : {}
}

function updateState(payload) {
  const data = normalizePayload(payload)
  const opening = !state.visible && data.visible === true
  state.visible = data.visible === true
  state.walkingInside = data.walkingInside === true
  state.canTravel = data.canTravel === true
  state.switching = data.switching === true
  state.vehicleCount = Number(data.vehicleCount) || 0
  state.groupCount = Number(data.groupCount) || 0
  state.groups = Array.isArray(data.groups) ? data.groups : []
  state.vehicles = Array.isArray(data.vehicles) ? data.vehicles : []
  state.nearbyVehicles = Array.isArray(data.nearbyVehicles) ? data.nearbyVehicles : []
  busy.value = state.switching
  if (!state.visible && !state.switching) selectedMap.value = null
  if (!state.visible) blocked.value = null
  if (opening) refreshNearby()
}

async function refreshNearby() {
  if (busy.value || carrierPending.value) return
  try {
    await callModLua('overhaul_career_garage_switchMap.refreshNearby')
  } catch {
    carrierError.value = 'Could not refresh nearby vehicles. Please try again.'
  }
}

function startVehicleDrag(event, inventoryId) {
  if (busy.value) return event.preventDefault()
  draggedVehicleId.value = Number(inventoryId)
  dropTargetId.value = null
  event.dataTransfer.effectAllowed = 'move'
  event.dataTransfer.setData('text/plain', String(inventoryId))
}

function dragOverVehicle(inventoryId) {
  const targetId = Number(inventoryId)
  dropTargetId.value = targetId !== draggedVehicleId.value ? targetId : null
}

async function dropOnVehicle(carrierInventoryId) {
  const childInventoryId = draggedVehicleId.value
  finishVehicleDrag()
  if (!childInventoryId || childInventoryId === Number(carrierInventoryId) || busy.value) return
  await assignCarrier(childInventoryId, carrierInventoryId)
}

async function assignCarrier(childInventoryId, carrierInventoryId) {
  if (busy.value || carrierPending.value) return
  carrierPending.value = true
  carrierError.value = ''
  try {
    const accepted = await callModLua('overhaul_career_garage_switchMap.setCarrierAssignment', Number(childInventoryId), Number(carrierInventoryId))
    if (accepted !== true) {
      carrierError.value = 'Could not group these vehicles. Both must be staged separately and the selection must not create a loop.'
      return
    }
    const data = await callModLua('overhaul_career_garage_switchMap.requestStagingData')
    if (data) updateState(data)
  } catch (_) {
    carrierError.value = 'Could not assign the carrier. Please try again.'
  } finally {
    carrierPending.value = false
  }
}

function isCarrierParent(inventoryId) {
  return state.vehicles.some(vehicle => Number(vehicle.carrierInventoryId || vehicle.coupledParentInventoryId) === Number(inventoryId))
}

function carrierOptions(inventoryId) {
  const group = state.groups.find(group => group.members?.some(member => Number(member.inventoryId) === Number(inventoryId)))
  const coupledIds = new Set((group?.members || []).map(member => Number(member.inventoryId)))
  return displayVehicles.value
    .filter(vehicle => vehicle.inventoryId !== Number(inventoryId) && !coupledIds.has(vehicle.inventoryId))
    .map(vehicle => ({ value: vehicle.inventoryId, label: vehicle.label }))
}

function finishVehicleDrag() {
  draggedVehicleId.value = null
  dropTargetId.value = null
}

async function clearCarrier(inventoryId) {
  if (busy.value || carrierPending.value) return
  carrierPending.value = true
  carrierError.value = ''
  try {
    const accepted = await callModLua('overhaul_career_garage_switchMap.clearCarrierAssignment', Number(inventoryId))
    if (accepted !== true) carrierError.value = 'Could not separate this vehicle. Please try again.'
    else {
      const data = await callModLua('overhaul_career_garage_switchMap.requestStagingData')
      if (data) updateState(data)
    }
  } catch (_) {
    carrierError.value = 'Could not separate this vehicle. Please try again.'
  } finally {
    carrierPending.value = false
  }
}

async function refreshMaps() {
  try {
    mapCatalog.value = await loadMapCatalog()
    const maps = await lua.overhaul_world_maps.getOtherAvailableMaps()
    if (!maps || typeof maps !== "object" || Array.isArray(maps) ||
        Object.values(maps).some(label => typeof label !== "string" || !label.trim())) {
      throw new Error("Invalid travel map reply")
    }
    mapOptions.value = Object.entries(maps || {})
      .map(([value, label]) => ({ value, label }))
      .sort((a, b) => a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }))
    if (selectedMap.value && !mapOptions.value.some(item => item.value === selectedMap.value)) {
      selectedMap.value = null
    }
    if (!selectedMap.value && mapOptions.value.length === 1) {
      selectedMap.value = mapOptions.value[0].value
    }
  } catch (error) {
    reportUiFailure(error, "MapTravelPanel: map discovery failed")
  }
}

function selectDestination(destination) {
  selectedMap.value = destination
  travelError.value = ''
}

function panelBounds() {
  const element = panel.value
  return {
    width: element?.offsetWidth || 360,
    height: element?.offsetHeight || 240,
  }
}

function clampPosition(save = false) {
  const margin = 12
  const bounds = panelBounds()
  position.x = Math.min(Math.max(margin, position.x), Math.max(margin, window.innerWidth - bounds.width - margin))
  position.y = Math.min(Math.max(margin, position.y), Math.max(margin, window.innerHeight - bounds.height - margin))
  position.ready = true
  if (save) savePosition()
}

function savePosition() {
  safeLua(() => window.localStorage.setItem(storageKey, JSON.stringify({ x: position.x, y: position.y })), "MapTravelPanel: savePosition")
}

function loadPosition() {
  try {
    const saved = JSON.parse(window.localStorage.getItem(storageKey) || 'null')
    if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) {
      position.x = saved.x
      position.y = saved.y
      clampPosition()
      return
    }
  } catch (_) { reportUiFailure(_, "MapTravelPanel: loadPosition") }
  resetPosition(false)
}

function resetPosition(save = true) {
  nextTick(() => {
    const bounds = panelBounds()
    position.x = window.innerWidth - bounds.width - 24
    position.y = Math.max(72, (window.innerHeight - bounds.height) / 2)
    clampPosition(save)
  })
}

function startDrag(event) {
  if (event.button !== 0) return
  dragState = {
    pointerId: event.pointerId,
    startX: event.clientX,
    startY: event.clientY,
    panelX: position.x,
    panelY: position.y,
  }
  event.currentTarget.setPointerCapture?.(event.pointerId)
  window.addEventListener('pointermove', dragPanel)
  window.addEventListener('pointerup', stopDrag)
  event.preventDefault()
}

function dragPanel(event) {
  if (!dragState || event.pointerId !== dragState.pointerId) return
  position.x = dragState.panelX + event.clientX - dragState.startX
  position.y = dragState.panelY + event.clientY - dragState.startY
  clampPosition()
}

function stopDrag(event) {
  if (dragState && event.pointerId === dragState.pointerId) {
    dragState = null
    clampPosition(true)
  }
  window.removeEventListener('pointermove', dragPanel)
  window.removeEventListener('pointerup', stopDrag)
}

async function confirmTravel() {
  if (!canPressTravel.value) return
  busy.value = true
  const destination = selectedMap.value
  try {
    const accepted = await lua.overhaul_career_garage_switchMap.switchMap(destination)
    if (accepted === true) return
    busy.value = false
    await showTravelBlockersIfAny(destination)
  } catch (_) {
    busy.value = false
  }
}

watch(selectedMap, () => { travelError.value = '' }, { flush: 'sync' })

watch(() => state.switching, switching => {
  if (!switching) return
  engaged.value = false
  blocked.value = null
  resolving.value = false
  busy.value = true
})

watch(shown, visible => {
  if (!visible) engaged.value = false
  if (!visible) return
  refreshMaps()
  nextTick(() => position.ready ? clampPosition() : loadPosition())
})
watch(minimized, () => nextTick(() => clampPosition(true)))

function onMapCatalogChanged() {
  if (shown.value) refreshMaps()
}

onMounted(() => {
  panelMounted = true
  bridge.events.on('MapTravelPanelEngage', engage)
  bridge.events.on('MapTravelStaging', updateState)
  bridge.events.on('MapTravelBlocked', onTravelBlocked)
  bridge.events.on('MapTravelUnavailable', onTravelUnavailable)
  bridge.events.on('OverhaulMapCatalogChanged', onMapCatalogChanged)
  window.addEventListener('resize', handleWindowResize)
  if (window.ResizeObserver) {
    resizeObserver = new window.ResizeObserver(() => position.ready && clampPosition())
    if (panel.value) resizeObserver.observe(panel.value)
  }
  safeLua(callModLua('overhaul_career_garage_switchMap.requestStagingData').then(payload => {
    if (panelMounted) updateState(payload)
  }), "MapTravelPanel: optional call")
})

watch(panel, element => {
  resizeObserver?.disconnect()
  if (element) resizeObserver?.observe(element)
})

onBeforeUnmount(() => {
  if (ownsMenu.value) reportPopupState(travelPopup, false)
  bridge.events.off('MapTravelPanelEngage', engage)
  panelMounted = false
  bridge.events.off('MapTravelStaging', updateState)
  bridge.events.off('MapTravelBlocked', onTravelBlocked)
  bridge.events.off('MapTravelUnavailable', onTravelUnavailable)
  bridge.events.off('OverhaulMapCatalogChanged', onMapCatalogChanged)
  resizeObserver?.disconnect()
  window.removeEventListener('resize', handleWindowResize)
  window.removeEventListener('pointermove', dragPanel)
  window.removeEventListener('pointerup', stopDrag)
})
</script>

<style scoped lang="scss">
/* Controller focus: the house ring (same values as rlsHouse.scss --focus / --focus-inset) for the game's
   controller class (.focus-visible) as well as :focus-visible, without the game's ::before frame (which
   never reaches this teleported panel anyway: it is outside the app root). */
$travel-focus-ring: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600), 0 0 0.9em -0.15em rgba(255, 102, 0, 0.55);
$travel-focus-inset: inset 0 0 0 2px var(--bng-orange-b400, #ff6600), inset 0 0 0 3.5px rgba(14, 14, 16, 0.6);
@mixin travel-focus($ring: $travel-focus-ring) {
  position: relative; // anchors the game's absolute frame on the control, never on an ancestor
  &.focus-visible {
    outline: none;
    box-shadow: $ring;
  }
  &.focus-visible::before {
    display: none !important;
  }
}

.pad-hint {
  display: inline-flex;
  align-items: center;
  font-size: calc(0.8 * var(--rls-u, 1rem));
  &:empty { display: none; }
}
// picked up with the pad: a quiet accent edge so it is clear the panel has the controls
.map-travel-panel.engaged { border-color: rgba(255, 102, 0, 0.55); }

.map-travel-layer {
  // one scaled unit for the whole panel: the same share of the screen at 720p..4K (it was rem-sized and
  // shrank to a corner sliver at 1440p), still following the player's UI scale
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  inset: 0;
  z-index: 1350;
  pointer-events: none;
}

.map-travel-panel {
  position: fixed;
  top: 0;
  left: 0;
  width: min(calc(26 * var(--rls-u, 1rem)), calc(100vw - calc(1.5 * var(--rls-u, 1rem))));
  overflow: hidden;
  color: #f5f7fa;
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  border: 1px solid rgba(255, 255, 255, 0.18);
  border-radius: calc(0.55 * var(--rls-u, 1rem));
  background: rgba(20, 24, 29, 0.94);
  box-shadow: 0 calc(0.8 * var(--rls-u, 1rem)) calc(2 * var(--rls-u, 1rem)) rgba(0, 0, 0, 0.46);
  pointer-events: auto;
  will-change: transform;
  --bng-icon-color: currentColor;
}

.map-travel-panel.minimized {
  width: min(calc(18 * var(--rls-u, 1rem)), calc(100vw - calc(1.5 * var(--rls-u, 1rem))));
}

.panel-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(0.55 * var(--rls-u, 1rem)) calc(0.55 * var(--rls-u, 1rem)) calc(0.55 * var(--rls-u, 1rem)) calc(0.65 * var(--rls-u, 1rem));
  user-select: none;
  background: rgba(0, 0, 0, 0.32);
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.header-drag {
  display: flex;
  align-items: center;
  gap: calc(0.45 * var(--rls-u, 1rem));
  min-width: 0;
  flex: 1 1 auto;
  cursor: move;
}

.header-title {
  margin: 0;
  font-size: calc(1.05 * var(--rls-u, 1rem));
  font-weight: 800;
  font-style: italic;
  letter-spacing: -0.01em;
  line-height: 1;
  white-space: nowrap;
}

.header-pill {
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  padding: 0.35em 0.55em 0.15em;
  border-radius: 0.35em;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.65);
  font-size: calc(0.72 * var(--rls-u, 1rem));
  font-weight: 700;
  line-height: 1;
}

.header-actions {
  display: flex;
  flex: 0 0 auto;
  gap: calc(0.25 * var(--rls-u, 1rem));
}

.hdr-btn {
  display: grid;
  place-items: center;
  width: calc(2 * var(--rls-u, 1rem));
  height: calc(2 * var(--rls-u, 1rem));
  padding: 0;
  color: rgba(255, 255, 255, 0.75);
  border: 0;
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.08);
  cursor: pointer;
  transition: background-color 0.12s, color 0.12s;
}

.hdr-btn svg {
  width: calc(1.05 * var(--rls-u, 1rem));
  height: calc(1.05 * var(--rls-u, 1rem));
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.hdr-btn:hover {
  color: #fff;
  background: rgba(255, 255, 255, 0.16);
}

.hdr-btn { @include travel-focus; }

.panel-content {
  display: flex;
  flex-direction: column;
  gap: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(0.65 * var(--rls-u, 1rem)) calc(0.7 * var(--rls-u, 1rem)) calc(0.7 * var(--rls-u, 1rem));
  max-height: min(85vh, calc(36 * var(--rls-u, 1rem)));
  overflow: hidden;
}

.section-title {
  margin: 0 0 calc(0.45 * var(--rls-u, 1rem));
  color: #aeb8c2;
  font-size: calc(0.68 * var(--rls-u, 1rem));
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.dest-section {
  display: flex;
  flex-direction: column;
  flex: 0 0 auto;
  min-height: 0;
}


.map-cards-scroll {
  --map-card-gap: calc(0.4 * var(--rls-u, 1rem));
  max-height: calc(
    ((min(calc(26 * var(--rls-u, 1rem)), calc(100vw - calc(1.5 * var(--rls-u, 1rem)))) - calc(1.4 * var(--rls-u, 1rem)) - var(--map-card-gap)) / 2 * 10 / 16) * 2 + var(--map-card-gap)
  );
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  padding-right: calc(0.1 * var(--rls-u, 1rem));
  scrollbar-gutter: stable;
}

.map-cards-scroll::-webkit-scrollbar {
  width: calc(0.35 * var(--rls-u, 1rem));
}

.map-cards-scroll::-webkit-scrollbar-thumb {
  background: rgba(255, 255, 255, 0.22);
  border-radius: var(--rls-u, 1rem);
}

.map-cards {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--map-card-gap);
}

.map-card {
  padding: 0;
  text-align: left;
  color: inherit;
  border: 2px solid rgba(255, 255, 255, 0.12);
  border-radius: calc(0.45 * var(--rls-u, 1rem));
  background: rgba(0, 0, 0, 0.35);
  overflow: hidden;
  cursor: pointer;
  transition: border-color 0.12s, box-shadow 0.12s;
}

.map-card:hover:not(:disabled) {
  border-color: rgba(246, 161, 94, 0.55);
}

// cards fill the scroll box edge to edge, where an outer ring would be clipped: inset ring
.map-card { @include travel-focus($travel-focus-inset); }
.staging-summary { @include travel-focus; border-radius: 0.3em; }

.map-card.selected {
  border-color: #f6a15e;
  box-shadow: 0 0 0 1px rgba(246, 161, 94, 0.35);
}

.map-card-art {
  display: block;
  aspect-ratio: 16 / 10;
  background-color: #1a1f24;
  background-size: cover;
  background-position: center;
  position: relative;
}

.map-card-name {
  position: absolute;
  right: 0;
  bottom: 0;
  left: 0;
  padding: calc(0.35 * var(--rls-u, 1rem)) calc(0.45 * var(--rls-u, 1rem)) calc(0.28 * var(--rls-u, 1rem));
  background: linear-gradient(180deg, rgba(0, 0, 0, 0) 0%, rgba(0, 0, 0, 0.82) 100%);
  font-size: calc(0.72 * var(--rls-u, 1rem));
  font-weight: 700;
  line-height: 1.15;
}

.hint {
  margin: 0;
  color: #aeb8c2;
  font-size: calc(0.78 * var(--rls-u, 1rem));
  line-height: 1.3;
}

.hint.warn {
  color: #f6c89a;
}

.kicker {
  font-size: calc(0.75 * var(--rls-u, 1rem));
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--bng-orange-b400, #ff6600);
}

.staging-details {
  flex: 1 1 auto;
  min-height: 0;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding-top: calc(0.25 * var(--rls-u, 1rem));
}

.staging-summary {
  margin-bottom: calc(0.35 * var(--rls-u, 1rem));
  cursor: pointer;
  list-style: none;
}

.staging-summary::-webkit-details-marker {
  display: none;
}

.staging-summary::before {
  content: "▸ ";
  color: rgba(255, 255, 255, 0.45);
}

.staging-details[open] .staging-summary::before {
  content: "▾ ";
}

.fleet-panel {
  --fleet-gap: calc(0.45 * var(--rls-u, 1rem));
  max-height: min(calc(13 * var(--rls-u, 1rem)), 30vh);
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;
  padding-right: calc(0.1 * var(--rls-u, 1rem));
}

.fleet-panel::-webkit-scrollbar { width: calc(0.4 * var(--rls-u, 1rem)); }
.fleet-panel::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: var(--rls-u, 1rem); }

.staging-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  gap: var(--fleet-gap);
}

.staging-tile {
  display: grid;
  gap: calc(0.35 * var(--rls-u, 1rem));
  min-width: 0;
  margin-left: calc(var(--depth, 0) * calc(0.55 * var(--rls-u, 1rem)));
  padding: calc(0.45 * var(--rls-u, 1rem)) calc(0.55 * var(--rls-u, 1rem)) calc(0.5 * var(--rls-u, 1rem));
  border-radius: calc(0.35 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid transparent;
}

.staging-tile.assigned { background: rgba(255, 102, 0, 0.14); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); }
.staging-tile.child { background: rgba(255, 255, 255, 0.04); }
.staging-tile.drop-target { border-color: #f6a15e; background: rgba(255, 102, 0, 0.14); }

.tile-main {
  display: grid;
  gap: calc(0.3 * var(--rls-u, 1rem));
  min-width: 0;
}

.tile-head {
  display: flex;
  align-items: center;
  gap: calc(0.35 * var(--rls-u, 1rem));
  min-width: 0;
}

.tile-name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  line-height: 1.2;
  font-size: calc(0.88 * var(--rls-u, 1rem));
  font-weight: 700;
}

.pills {
  display: inline-flex;
  flex: 0 0 auto;
  flex-wrap: nowrap;
  align-items: center;
  justify-content: flex-end;
  gap: calc(0.25 * var(--rls-u, 1rem));
  margin-left: auto;
}

.pill {
  display: inline-flex;
  align-items: center;
  gap: calc(0.25 * var(--rls-u, 1rem));
  padding: 0.35em 0.5em 0.1em;
  line-height: 1;
  border-radius: 0.3em;
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.8);
  font-size: 0.72em;
  font-weight: 700;
  white-space: nowrap;
}

.pill.accent { background: rgba(255, 102, 0, 0.25); color: #ffb27a; }
.pill.soft {
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.68em;
}

.vehicle-tools {
  display: flex;
  align-items: center;
  gap: calc(0.35 * var(--rls-u, 1rem));
  min-width: 0;
}

.vehicle-tools .travel-dropdown { flex: 1 1 auto; min-width: 0; }

.nearby-block {
  margin-top: calc(0.45 * var(--rls-u, 1rem));
  padding-top: calc(0.45 * var(--rls-u, 1rem));
  border-top: 1px dashed rgba(255, 255, 255, 0.12);
}

.nearby-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.4 * var(--rls-u, 1rem));
  margin-bottom: calc(0.35 * var(--rls-u, 1rem));
}

.carrier-error {
  margin: 0 0 calc(0.35 * var(--rls-u, 1rem));
  color: #fca5a5;
  font-size: calc(0.78 * var(--rls-u, 1rem));
  font-weight: 600;
}

.btn {
  appearance: none;
  border: 0;
  margin: 0;
  padding: calc(0.55 * var(--rls-u, 1rem)) calc(0.85 * var(--rls-u, 1rem)) calc(0.45 * var(--rls-u, 1rem));
  border-radius: calc(0.55 * var(--rls-u, 1rem));
  font: inherit;
  font-weight: 700;
  line-height: 1;
  color: #fff;
  background: rgba(255, 255, 255, 0.1);
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 0.12s, transform 0.08s;
}

.btn:hover:not(:disabled) { background: rgba(255, 255, 255, 0.18); }
.btn:active:not(:disabled) { transform: translateY(1px); }
.btn { @include travel-focus; }
.btn-glyph { margin-right: 0.4em; vertical-align: -0.15em; }
.btn:disabled { opacity: 0.45; cursor: default; transform: none; }
.btn-primary { background: var(--bng-orange-b400, #ff6600); padding: calc(0.72 * var(--rls-u, 1rem)) var(--rls-u, 1rem) calc(0.58 * var(--rls-u, 1rem)); }
.btn-primary:hover:not(:disabled) { background: #ff7a1f; }
.btn-ghost { padding: calc(0.45 * var(--rls-u, 1rem)) calc(0.65 * var(--rls-u, 1rem)) calc(0.35 * var(--rls-u, 1rem)); font-size: calc(0.72 * var(--rls-u, 1rem)); background: rgba(255, 255, 255, 0.08); }

.travel-button {
  flex: 0 0 auto;
  width: 100%;
  margin-top: calc(0.15 * var(--rls-u, 1rem));
}

.travel-modal-backdrop {
  position: fixed;
  inset: 0;
  display: grid;
  place-items: center;
  padding: calc(1.5 * var(--rls-u, 1rem));
  background: rgba(0, 0, 0, 0.55);
  pointer-events: auto;
}

.travel-modal {
  position: relative;
  top: auto;
  left: auto;
  width: min(calc(30 * var(--rls-u, 1rem)), calc(100vw - calc(3 * var(--rls-u, 1rem))));
  will-change: auto;
}

.header-drag.static { cursor: default; }

.modal-content { max-height: min(80vh, calc(34 * var(--rls-u, 1rem))); }

.modal-list {
  list-style: none;
  margin: 0;
  padding: 0;
  max-height: min(40vh, calc(18 * var(--rls-u, 1rem)));
  overflow-y: auto;
  overscroll-behavior: contain;
  scrollbar-gutter: stable;
  border-radius: calc(0.35 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.06);
}

.modal-list::-webkit-scrollbar { width: calc(0.4 * var(--rls-u, 1rem)); }
.modal-list::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: var(--rls-u, 1rem); }

.modal-row {
  padding: calc(0.5 * var(--rls-u, 1rem)) calc(0.65 * var(--rls-u, 1rem)) calc(0.55 * var(--rls-u, 1rem));
  min-width: 0;
}

.modal-row + .modal-row { border-top: 1px solid rgba(255, 255, 255, 0.08); }

.tile-sub {
  color: rgba(255, 255, 255, 0.55);
  font-size: calc(0.72 * var(--rls-u, 1rem));
  line-height: 1.25;
}

.pill.fine { background: rgba(252, 165, 165, 0.16); color: #fca5a5; }

.modal-total {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(0.5 * var(--rls-u, 1rem));
  padding: calc(0.55 * var(--rls-u, 1rem)) calc(0.65 * var(--rls-u, 1rem)) calc(0.45 * var(--rls-u, 1rem));
  border-radius: calc(0.35 * var(--rls-u, 1rem));
  background: rgba(255, 255, 255, 0.06);
  color: #aeb8c2;
  font-size: calc(0.78 * var(--rls-u, 1rem));
}

.modal-total strong { color: #f5f7fa; font-size: calc(0.95 * var(--rls-u, 1rem)); }
.modal-total strong.fine { color: #fca5a5; }

.modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: calc(0.45 * var(--rls-u, 1rem));
  margin-top: calc(0.15 * var(--rls-u, 1rem));
}

.modal-actions .btn-ghost { padding: calc(0.72 * var(--rls-u, 1rem)) calc(0.9 * var(--rls-u, 1rem)) calc(0.58 * var(--rls-u, 1rem)); font-size: inherit; }

/* Game currency glyph before amounts; inherits colour/size. */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>

<style lang="scss">
.bng-dropdown.travel-dropdown {
  --bng-dropdown-bg: rgba(255, 255, 255, 0.1);
  --bng-dropdown-bg-hover: rgba(255, 255, 255, 0.16);
  --bng-dropdown-bg-active: rgba(255, 255, 255, 0.2);
  margin: 0;
  min-width: 0;
  width: 100%;
  padding: 0.5em 0.65em 0.4em 0.75em;
  border-radius: 0.55em;
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  font-size: calc(0.78 * var(--rls-u, 1rem));
  font-weight: 700;
  color: #fff;
  position: relative;
  &:focus::before,
  &.focus-visible::before { display: none !important; }
  // controller focus: the house ring for the game's .focus-visible class as well as :focus-visible
  &.focus-visible { outline: none; box-shadow: 0 0 0 1.5px rgba(14, 14, 16, 0.95), 0 0 0 3.5px var(--bng-orange-b400, #ff6600), 0 0 0.9em -0.15em rgba(255, 102, 0, 0.55); }
  & > .dropdown-arrow { order: 2; margin-left: auto; padding-left: 0.45em; font-size: 1.05em; color: var(--bng-orange-b400, #ff6600); }
  .dropdown-display { flex: 1 1 auto; min-width: 0; }
  .dropdown-display-label { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
}

.bng-popover:has(> .bng-dropdown-content.travel-dropdown) {
  padding: 0;
  background: transparent;
  box-shadow: none;
  border: 0;
  > .bng-popover-arrow { display: none; }
}

.bng-dropdown-content.travel-dropdown {
  --rls-u: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem); // popover is teleported out of the panel
  font-size: calc(0.82 * var(--rls-u, 1rem));
  background: #232326;
  border-radius: 0.6em;
  padding: 0.3em;
  box-shadow: 0 14px 34px rgba(0, 0, 0, 0.65), inset 0 0 0 1px rgba(255, 255, 255, 0.08);
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  max-height: min(50vh, 16em);
  .dropdown-option {
    --dropdown-option-hover-bg: rgba(255, 255, 255, 0.1);
    --dropdown-option-active-bg: rgba(255, 255, 255, 0.16);
    border-radius: 0.4em;
    padding: 0.55em 0.75em 0.42em;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.85);
    &.selected { background-color: var(--bng-orange-b400, #ff6600) !important; color: #fff; }
  }
}
</style>
