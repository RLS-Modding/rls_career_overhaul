<template>
  <ComputerWrapper :title="computerStore.computerData.facilityName + ' - Home screen'" close @back="close">

    <BngCard class="card-content rls-house rls-house-card" v-bng-blur="1">
      <BngCardHeading v-if="computerLoading" type="ribbon">
        Loading...
      </BngCardHeading>

      <div v-if="!computerLoading" class="computer-actions scroll" v-bng-ui-nav-scroll>
        <div class="action-header">
          <div class="line left"></div>
          <div class="title">Vehicle Management</div>
          <div class="line right"></div>
        </div>
        <div v-if="hasVehicles" class="vehicle-select-container">
          <div class="vehicle-hero">
            <div class="hero-photo" :class="{ locked: !!vehicleLock }">
              <img v-if="vehicleThumb && !brokenImages.has(vehicleThumb)" :src="vehicleThumb" alt="" @error="markBroken(vehicleThumb)" />
              <span v-if="vehicleClass" class="photo-tag">{{ vehicleClass }}</span>
              <span v-if="currentVehicleData?.listedForAuction" class="photo-tag right">At auction</span>
              <div v-if="vehicleLock" class="hero-lock">
                <strong>{{ vehicleLock.reason }}</strong>
                <span v-if="vehicleLock.eta">{{ vehicleLock.eta }}</span>
              </div>
            </div>

            <div class="hero-info">
              <template v-if="currentVehicleData">
                <div class="hero-name">
                  <template v-if="!renaming">
                    <span class="name-text">{{ currentVehicleData.niceName }}</span>
                    <button v-if="canRename" ref="renameBtn" class="rename-btn" title="Rename vehicle" bng-nav-item
                      v-bng-on-ui-nav:ok.asMouse.focusRequired @click="startRename">
                      <BngIcon :type="icons.edit" />
                    </button>
                  </template>
                  <form v-else class="rename-form" @submit.prevent="saveRename(true)">
                    <input ref="renameInput" v-model="renameDraft" v-bng-text-input class="rename-input"
                      :class="{ invalid: !renameValid }" maxlength="30" spellcheck="false"
                      v-bng-on-ui-nav:back.focusRequired="cancelRename"
                      @keydown.esc.stop.prevent="cancelRename" @blur="saveRename(false)" />
                  </form>
                </div>
                <div class="hero-value" v-if="!currentVehicleData.returnLoanerPermission?.allow">
                  <BngUnit :money="currentVehicleData.marketSellValue || currentVehicleData.value" />
                  <span v-if="isDamaged && currentVehicleData.valueRepaired" class="hero-value-note">
                    <BngUnit :money="currentVehicleData.valueRepaired" /> repaired
                  </span>
                </div>

                <!-- fixed three lines so switching cars never changes the height -->
                <div class="hero-specs">
                  <div class="spec">
                    <BngIcon class="spec-icon" :type="icons.odometer" />
                    <span>{{ vehicleMileage || "—" }}</span>
                  </div>
                  <div class="spec" :class="{ bad: currentVehicleData.isInsured === false }">
                    <BngIcon class="spec-icon" :type="icons.shieldCheckmark" />
                    <span>{{ currentVehicleData.isInsured === false ? "Not insured" : $translate.instant(currentVehicleData.insuranceInfo?.name || "No insurance") }}</span>
                  </div>
                  <div class="spec" :class="{ bad: isDamaged }">
                    <BngIcon class="spec-icon" :type="icons.wrench" />
                    <span v-if="isDamaged">{{ currentVehicleData.needsRepair ? "Needs repair" : "Worn" }}<template v-if="vehicleCondition !== null">, {{ vehicleCondition }}%</template></span>
                    <span v-else>No damage</span>
                  </div>
                </div>
              </template>

              <!-- pick a car by its photo; LB / RB still cycle on a controller -->
              <div v-if="showVehicleSelectorButtons" class="hero-picker">
                <span class="picker-bind" v-bng-on-ui-nav:tab_l.asMouse @click="switchActiveVehicle(-1)">
                  <BngBinding ui-event="tab_l" controller />
                </span>
                <button class="picker-arrow" :disabled="!canScrollLeft" aria-label="Scroll vehicles left" @click="scrollPage(-1)">&#8249;</button>
                <div ref="strip" class="picker-strip" aria-label="Owned vehicles">
                  <button v-for="(veh, idx) in computerStore.computerData.vehicles" :key="veh.inventoryId"
                    class="picker-thumb" :class="{ active: veh.inventoryId == computerStore.activeInventoryId }"
                    bng-nav-item tabindex="0" v-bng-on-ui-nav:ok.asMouse.focusRequired
                    :aria-label="veh.vehicleName" :aria-pressed="veh.inventoryId == computerStore.activeInventoryId"
                    :title="veh.vehicleName" @click="selectVehicle(idx)">
                    <img v-if="veh.thumbnail && !brokenImages.has(veh.thumbnail)" :src="veh.thumbnail" alt="" @error="markBroken(veh.thumbnail)" />
                    <span v-else class="picker-name">{{ veh.vehicleName }}</span>
                  </button>
                </div>
                <button class="picker-arrow" :disabled="!canScrollRight" aria-label="Scroll vehicles right" @click="scrollPage(1)">&#8250;</button>
                <span class="picker-bind" v-bng-on-ui-nav:tab_r.asMouse @click="switchActiveVehicle(1)">
                  <BngBinding ui-event="tab_r" controller />
                </span>
              </div>
            </div>
          </div>

          <div class="actions-list"
            v-if="computerStore.activeInventoryId && computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId]">
            <div class="computer-function-tile"
              v-for="(computerFunction, index) in computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId]"
              :key="computerFunction.id" :class="{ 'action-disabled': computerFunction.disabled }" tabindex="0"
              :bng-route-target="routeOf(computerFunction)"
              :bng-scoped-nav-autofocus="isEntryTile(computerFunction) ? true : undefined"
              bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
              @click="computerButtonCallback(computerFunction, computerStore.activeInventoryId)"
              @mouseover="setReason(0, infoById[computerFunction.id].reason)"
              @focus="setReason(0, infoById[computerFunction.id].reason)" @mouseleave="setReason(0)"
              @blur="setReason(0)" v-bng-ui-nav-focus="index == 0 ? 0 : undefined">
              <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
              <span class="label">{{ infoById[computerFunction.id].label }}</span>
              <BngIcon v-if="computerFunction.disabled" class="lock" :type="icons.lockClosed" />
            </div>
          </div>
        </div>

        <div v-else class="no-vehicle-container">
          <BngIcon class="empty-badge" :type="icons.keys1" />
          <span>No vehicles in garage.</span>
          <p> Place a vehicle in your garage to access modify and manage it.</p>
        </div>

        <div class="action-header" v-if="computerStore.generalComputerFunctions">
          <div class="line left"></div>
          <div class="title">General Computer Functions</div>
          <div class="line right"></div>
        </div>
        <div v-if="computerStore.generalComputerFunctions" class="general-functions-container">
          <div class="actions-list">
            <template v-for="(computerFunction, index) in computerStore.generalComputerFunctions"
              :key="computerFunction.id">
              <div class="computer-function-tile" v-if="!computerFunction.type"
                :class="{ 'action-disabled': computerFunction.disabled }" tabindex="0" bng-nav-item
                :bng-route-target="routeOf(computerFunction)"
                :bng-scoped-nav-autofocus="isEntryTile(computerFunction) ? true : undefined"
                v-bng-on-ui-nav:ok.asMouse.focusRequired @click="computerButtonCallback(computerFunction)"
                @mouseover="setReason(1, infoById[computerFunction.id].reason)"
                @focus="setReason(1, infoById[computerFunction.id].reason)" @mouseleave="setReason(1)"
                @blur="setReason(1)" v-bng-ui-nav-focus="!hasVehicles && index == 0 ? 0 : undefined">
                <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
                <span class="label">{{ infoById[computerFunction.id].label }}</span>
                <BngIcon v-if="computerFunction.disabled" class="lock" :type="icons.lockClosed" />
              </div>
            </template>
            <div class="computer-function-tile" tabindex="0" bng-nav-item bng-route-target="garage-listings"
              :bng-scoped-nav-autofocus="entryTileId === 'garageListings' ? true : undefined"
              v-bng-on-ui-nav:ok.asMouse.focusRequired @click.stop="openGarageListings" @mousedown.stop
              @mouseleave="setReason(1)" @blur="setReason(1)">
              <BngIcon class="icon" :type="icons.beamCurrency" />
              <span class="label">Garage Listings</span>
            </div>
          </div>
          <div class="disable-reason" v-if="disableReason[0]">
            <BngIcon class="disable-icon" v-show="disableReason[0]" :type="icons.info" />
            <span v-html="disableReason[0] || '&nbsp;'"></span>
          </div>
          <div class="disable-reason" v-if="disableReason[1]">
            <BngIcon class="disable-icon" :type="icons.info" />
            <span v-html="disableReason[1] || '&nbsp;'"></span>
          </div>
        </div>

        <div class="action-header" v-if="computerStore.activityComputerFunctions?.length">
          <div class="line left"></div>
          <div class="title">Activities & Events</div>
          <div class="line right"></div>
        </div>
        <div class="activities-container" v-if="computerStore.activityComputerFunctions?.length">
          <div class="actions-list">
            <template v-for="(computerFunction, index) in computerStore.activityComputerFunctions"
              :key="computerFunction.id">
              <div class="computer-function-tile" v-if="!computerFunction.type"
                :class="{ 'action-disabled': computerFunction.disabled }" tabindex="0" bng-nav-item
                :bng-route-target="routeOf(computerFunction)"
                :bng-scoped-nav-autofocus="isEntryTile(computerFunction) ? true : undefined"
                v-bng-on-ui-nav:ok.asMouse.focusRequired @click="computerButtonCallback(computerFunction)"
                @mouseover="setReason(2, infoById[computerFunction.id].reason)"
                @focus="setReason(2, infoById[computerFunction.id].reason)" @mouseleave="setReason(2)"
                @blur="setReason(2)">
                <BngIcon class="icon" :type="infoById[computerFunction.id].icon" />
                <span class="label">{{ infoById[computerFunction.id].label }}</span>
                <BngIcon v-if="computerFunction.disabled" class="lock" :type="icons.lockClosed" />
              </div>
            </template>
          </div>
          <div class="disable-reason" v-if="disableReason[2]">
            <BngIcon class="disable-icon" :type="icons.info" />
            <span v-html="disableReason[2] || '&nbsp;'"></span>
          </div>
        </div>
      </div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { useVehicleStrip } from "../composables/useVehicleStrip.js"
import { $translate } from "@/services/translation"
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, onMounted, onUnmounted, watch, nextTick } from "vue"
import { lua } from "@/bridge"
import { useComputerStore } from "../stores/computerStore"
import ComputerWrapper from "./ComputerWrapper.vue"
import { BngButton, ACCENTS, BngCard, BngCardHeading, BngBinding, BngIcon, BngUnit, icons } from "@/common/components/base"
import { vBngOnUiNav, vBngBlur, vBngUiNavFocus, vBngTextInput, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import { formatSanctionedClassWithBucket } from "../utils/sanctionedClassFormat"
import { formatAccessEta } from "../utils/accessEta.js"
import { useRouteDataStore } from "@/services/routeData"
import { useScreenEntry, refocusIfLost } from "../composables/useScreenEntryFocus"
import { computerFunctionRoute, computerFunctionIcon, computerFunctionsReady, retryComputerFunctionsWhileMounted } from "../utils/computerFunctionCatalog.js"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()
const { units } = useBridge()
const computerStore = useComputerStore()
const currentVehicleData = ref(null)
const { strip, canScrollLeft, canScrollRight, scrollPage } = useVehicleStrip(() => computerStore.activeInventoryId)

// Vehicle showcase: only what the rest of the screen doesn't already say
// (the title names this garage, so location shows only when the car is elsewhere).
const vehicleThumb = computed(() => {
  const d = currentVehicleData.value
  return d?.thumbnail ? `${d.thumbnail}?${d.dirtyDate}` : null
})


const vehicleCondition = computed(() => {
  const average = currentVehicleData.value?.conditionAvg
  return Number.isFinite(average) ? Math.round(average * 100) : null
})

const isDamaged = computed(() => {
  const d = currentVehicleData.value
  return !!d && (!!d.needsRepair || (vehicleCondition.value !== null && vehicleCondition.value < 100))
})

const conditionClass = computed(() => {
  const c = vehicleCondition.value
  if (currentVehicleData.value?.needsRepair || (c !== null && c < 60)) return "bad"
  return "warn"
})

const vehicleClass = computed(() => {
  const d = currentVehicleData.value
  if (!d) return null
  let pw = Number(d.powerPerWeight)
  if (!(pw > 0)) {
    const hp = Number(d.certificationData?.power), kg = Number(d.certificationData?.weight)
    pw = hp > 0 && kg > 0 ? hp / kg : null
  }
  const label = d.savedVehicleClassUi?.label || d.certificationData?.vehicleClass?.label || d.certificationData?.vehicleClass?.name
  return formatSanctionedClassWithBucket(label, pw) || null
})

const vehicleLock = computed(() => {
  const d = currentVehicleData.value
  if (!d) return null
  if (d._message) return { reason: d._message }
  if (d.missingFile) return { reason: "Missing file" }
  if (d.timeToAccess) {
    const eta = formatAccessEta(d.timeToAccess)
    const reasons = { engineRetailPickup: "Ready at engine shop", engineRetailInstall: "Engine swap in progress", bought: "Out for delivery", repair: "Being repaired", rented: "At the film studio" }
    return { reason: reasons[d.delayReason] || "Available in", eta: d.delayReason === "engineRetailPickup" ? null : eta }
  }
  return null
})

// Rename in place: pencil -> input; Enter or leaving the field saves, Esc cancels.
// Same rules as overhaul_career_garage_inventory.isVehicleNameValid (no quotes, backslashes or control chars).
const renaming = ref(false)
const renameDraft = ref("")
const renameInput = ref(null)
const renameValid = computed(() => {
  const t = renameDraft.value.trim()
  return t.length > 0 && !/["\x5C\x08\f\n\r\t]/.test(t)
})
const canRename = computed(() => !!currentVehicleData.value && !currentVehicleData.value.listedForAuction)

const renameBtn = ref(null)
const startRename = async () => {
  renameDraft.value = currentVehicleData.value?.niceName || ""
  renaming.value = true
  await nextTick()
  renameInput.value?.focus()
  renameInput.value?.select()
}
// B / Esc / Enter leave the field; a pad keeps going from the pencil instead of <body>
// (not on blur: then the player already moved focus somewhere else)
const refocusRename = () => refocusIfLost(() => renameBtn.value, { force: true })
const cancelRename = () => {
  renaming.value = false
  refocusRename()
}
const saveRename = async (fromSubmit = false) => {
  if (!renaming.value) return
  renaming.value = false
  if (fromSubmit) refocusRename()
  const veh = currentVehicleData.value
  const name = renameDraft.value.trim()
  if (!veh || !renameValid.value || name === veh.niceName) return
  const inventoryId = Number(veh.id ?? computerStore.activeInventoryId)
  const ok = await lua.overhaul_career_garage_inventory.renameVehicle(inventoryId, name)
  if (ok === false) return
  veh.niceName = name
  const listed = (computerStore.computerData.vehicles || []).find(v => v.inventoryId == inventoryId)
  if (listed) listed.vehicleName = name
}
// switching cars mid-edit drops the edit
watch(() => computerStore.activeInventoryId, () => { renaming.value = false })

// thumbnails that failed to load fall back to the plain photo well / the car name
const brokenImages = ref(new Set())
const markBroken = url => { brokenImages.value = new Set(brokenImages.value).add(url) }

const vehicleMileage = computed(() => {
  const m = Number(currentVehicleData.value?.mileage)
  return m > 0 ? units.buildString("length", m, 0) : null
})

const selectVehicle = idx => {
  const list = computerStore.computerData.vehicles || []
  const cur = list.findIndex(v => v.inventoryId == computerStore.activeInventoryId)
  if (idx !== cur) computerStore.switchActiveVehicle(idx - cur)
}


const openGarageListings = () => {
  lua.extensions.ui_router.navigate('garage-listings')
}

let vehicleRequestGeneration = 0
let vehicleViewAlive = true
const updateVehicleData = async newId => {
  const generation = ++vehicleRequestGeneration
  currentVehicleData.value = null
  if (!Number.isFinite(Number(newId)) || !Number(newId)) return
  try {
    const data = await lua.overhaul_career_garage_inventory.getVehicleUiData(newId)
    if (vehicleViewAlive && generation === vehicleRequestGeneration && newId === computerStore.activeInventoryId) {
      currentVehicleData.value = data
    }
  } catch (_err) { reportUiFailure(_err, "update vehicle data (ComputerMain)") }
}
watch(() => computerStore.activeInventoryId, updateVehicleData, { flush: "sync" })

const showVehicleSelectorButtons = computed(() => computerStore.computerData.vehicles && computerStore.computerData.vehicles.length > 1 )

const hasVehicles = computed(() => computerStore.computerData.vehicles && computerStore.computerData.vehicles.length)

// list of function IDs that are known to take some time, so we inform the user about loading
const slowFunctions = ["vehicleShop", "partInventory"]
const computerLoading = ref(false)

const computerButtonCallback = (computerFunction, inventoryId = undefined) => {
  if (computerFunction.disabled) return
  if (slowFunctions.includes(computerFunction.id)) {
    computerLoading.value = true
    // for some reason, both nextTick and window.requestAnimationFrame does not produce the desired result
    setTimeout(() => computerStore.computerButtonCallback(computerFunction.id, inventoryId), 100)
  } else {
    computerStore.computerButtonCallback(computerFunction.id, inventoryId)
  }
}
const switchActiveVehicle = computerStore.switchActiveVehicle

// Controller entry: land on the tile of the screen we came back from (bng-route-target), else the
// first tile. Lua hooks can override routeTarget; discovered manifests supply the other hints.
const routeOf = computerFunctionRoute
const routeDataStore = useRouteDataStore()
const entryDone = ref(false)
const visibleTiles = computed(() => [
  ...((computerStore.activeInventoryId && computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId]) || []),
  ...(computerStore.generalComputerFunctions || []).filter(f => !f.type),
  { id: "garageListings", routeTarget: "garage-listings" },
  ...(computerStore.activityComputerFunctions || []).filter(f => !f.type),
])
const entryTileId = computed(() => {
  // only for the first focus; later scope resumes (after a popup) go back to the last focused tile
  if (entryDone.value) return null
  const from = routeDataStore.fromRoute?.name
  const tiles = visibleTiles.value
  const back = from && tiles.find(f => {
    const route = routeOf(f)
    return route && (from === route || from.startsWith(route + "."))
  })
  return (back || tiles[0])?.id ?? null
})
const isEntryTile = fn => !!fn && fn.id === entryTileId.value
const tilesReady = computed(() => computerFunctionsReady.value && !computerLoading.value && visibleTiles.value.length > 1)
watch(tilesReady, ready => {
  if (!ready || entryDone.value) return
  // the scope picks its focus asynchronously; keep the autofocus mark until it has
  focusScreenEntry().then(() => setTimeout(() => { entryDone.value = true }, 600))
}, { immediate: true })


const infoById = computed(() => [
  ...computerStore.generalComputerFunctions,
  ...(computerStore.activeInventoryId ? computerStore.vehicleSpecificComputerFunctions[computerStore.activeInventoryId] : undefined) || [],
  ...computerStore.activityComputerFunctions,
].reduce((res, func) => {
  res[func.id] = {
    icon: computerFunctionIcon(func.id),
    label: func.label,
    reason: undefined,
  }
  if (func.reason) {
    /// nbsp by size:
    // narrow: " "
    // normal: " "
    // figure: " "
    res[func.id].label += " *"
    // string "func.disableReason" is for backward compatibility with an old style
    res[func.id].reason = func.reason.label
    // TODO: alternate something when "func.disableReason.type" is not "text" (discussion is on-going)
  }
  return res
}, {}))

const disableReason = ref([null, null, null])
const setReason = (idx, reason = null) => {
  disableReason.value = disableReason.value.map((_, i) => i === idx ? reason : null)
}

const close = () => {
  if (computerLoading.value) return
  lua.overhaul_career_career.closeAllMenus()
}

let stopCatalogRetries = () => {}
const start = async () => {
  computerStore.requestComputerData()
  updateVehicleData(computerStore.activeInventoryId)
  stopCatalogRetries = retryComputerFunctionsWhileMounted()
}

const kill = () => {
  stopCatalogRetries()
  vehicleViewAlive = false
  vehicleRequestGeneration++
  computerStore.onMenuClosed()
  computerStore.$dispose()
}


onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Sizing: everything is em off the card's font-size, which follows the viewport height
   (.rls-house-card), so the hub keeps the same share of the screen at 720p..4K. */
.card-content.rls-house {
  --bng-card-height: auto;
  --bg-opacity: 0.9; /* the card's default 0.6 reads grey over bright garages */
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(54em, 100%);
  max-width: 100%;
  max-height: 100%;
  min-height: 0;
  border-radius: 0.6em;
  overflow: hidden;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  & :deep(.card-cnt) {
    flex: 1 1 auto;
    min-height: 0;
    border-radius: 0.6em;
    background-color: rgba(var(--bng-off-black-rgb), var(--bg-opacity));
  }
  & :deep(.card-heading) {
    font-size: 1.45em;
  }
  /* no blue-grey footer band */
  & :deep(.footer-container) {
    background-color: rgba(var(--bng-off-black-rgb), 0.82);
    border-top: 1px solid var(--line);
  }
}

.computer-actions {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  padding: 0.9em 0.6em 1em 1em; /* right side leaves room for the slim scrollbar gutter */
  overscroll-behavior: contain;
}

.vehicle-select-container,
.general-functions-container,
.activities-container {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  padding-bottom: var(--space-2);
}

/* Section head: small faint caps + hairline rule (house .split-head / .caption) */
.action-header {
  display: flex;
  align-items: center;
  gap: 0.7em;
  margin-top: 0.15em;

  .title {
    flex: 0 0 auto;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    line-height: 1;
    text-transform: uppercase;
    color: var(--faint);
    padding-top: 0.15em; /* Overpass caps sit high */
  }
  /* reset the house .line list-row styles; here it is only a rule */
  .line {
    display: block;
    flex: 1 1 auto;
    height: 1px;
    min-width: 0;
    padding: 0;
    border: 0;
    background: var(--line);
    &.left {
      display: none;
    }
  }
}

/* Vehicle showcase: big photo left; name, value, three fixed spec lines and the
   car picker on the right. Fixed height: nothing appears or disappears per car. */
.vehicle-hero {
  display: grid;
  grid-template-columns: minmax(0, 25em) minmax(0, 1fr);
  gap: 1.1em;
  padding: 0.6em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

/* the photo fills the hero height (set by the info column), so no strip of panel shows under it */
.hero-photo {
  position: relative;
  align-self: stretch;
  min-height: 0;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &.locked img {
    filter: brightness(45%) saturate(50%);
  }
}

.photo-tag {
  position: absolute;
  top: 0.5em;
  left: 0.5em;
  padding: 0.4em 0.5em 0.15em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.78);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.74em;
  font-weight: 700;
  line-height: 1;
  &.right {
    left: auto;
    right: 0.5em;
    color: var(--money);
  }
}

.hero-lock {
  position: absolute;
  inset: 0;
  display: grid;
  place-content: center;
  gap: 0.15em;
  text-align: center;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.9);
  strong {
    font-size: 1.15em;
    font-weight: 800;
  }
  span {
    color: var(--muted);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}

.hero-info {
  display: flex;
  flex-direction: column;
  min-width: 0;
  /* room for a two-line name, so the hero keeps one height whichever car is shown
     (padding + 2-line name + value + specs + picker; a one-line name leaves the slack above the picker) */
  min-height: 16.7em;
  padding: 0.25em 0.2em 0 0;
}

.hero-name {
  display: flex;
  align-items: flex-start;
  gap: 0.35em;
  min-width: 0;
  font-size: 1.5em;
  font-weight: 800;
  line-height: 1.15;
  /* long names get two lines before the ellipsis (the photo sets the hero height, so there is room) */
  span {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    min-width: 0;
    overflow: hidden;
    overflow-wrap: anywhere;
  }
  .rename-btn {
    margin-top: 0.07em; /* centred on the first line */
  }
}
.rename-btn {
  // positioned so any ::before (the game's focus frame) anchors to the button, not to the panel
  position: relative;
  appearance: none;
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 1.5em;
  height: 1.5em;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--faint);
  font-size: 0.7em;
  cursor: pointer;
  transition: color 120ms ease, background-color 120ms ease;
  &:hover,
  &:focus-visible,
  &.focus-visible {
    color: #fff;
    background: var(--panel-2);
  }
  @include house-focus;
}
.rename-form {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
}
.rename-input {
  width: 100%;
  min-width: 0;
  margin: 0;
  padding: 0.1em 0.3em 0;
  border: 0;
  border-radius: var(--radius-thumb);
  background: rgba(0, 0, 0, 0.35);
  box-shadow: inset 0 0 0 1px var(--line);
  color: #fff;
  font: inherit;
  line-height: 1.15;
  &:focus {
    outline: none;
    box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.35);
  }
  &.invalid {
    box-shadow: inset 0 0 0 1px var(--bad);
  }
}

.hero-value {
  display: flex;
  align-items: baseline;
  gap: 0.6em;
  margin-top: 0.3em;
  color: var(--money);
  font-size: 1.15em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  .hero-value-note {
    color: var(--faint);
    font-size: 0.72em;
    font-weight: 600;
  }
  :deep(.bng-unit), :deep(.unit) {
    color: inherit;
  }
}

.hero-specs {
  display: grid;
  gap: 0.5em;
  margin-top: 1em;
}
.spec {
  display: flex;
  align-items: center;
  gap: 0.55em;
  min-width: 0;
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  span {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    padding-top: 0.1em;
  }
  .spec-icon {
    flex: 0 0 auto;
    width: 1.25em;
    font-size: 1.35em;
    color: var(--faint);
  }
  &.bad,
  &.bad .spec-icon {
    color: var(--bad);
  }
}

/* car picker: small photos, the shown car full strength, the rest dimmed */
.hero-picker {
  display: flex;
  align-items: center;
  gap: 0.4em;
  margin-top: auto;
  padding-top: 0.7em;
  min-width: 0;
}
.picker-bind {
  flex: 0 0 auto;
  &:empty {
    display: none;
  }
}
.picker-arrow {
  flex: 0 0 1.2em;
  align-self: stretch;
  border: 0;
  border-radius: var(--radius-thumb);
  background: var(--panel-2);
  color: var(--accent);
  font: inherit;
  font-size: 1.3em;
  cursor: pointer;
  &:disabled { opacity: 0.25; cursor: default; }
  &:hover:not(:disabled), &.focus-visible { background: var(--panel); outline: 2px solid var(--accent); }
}
.picker-strip {
  display: flex;
  gap: 0.4em;
  min-width: 0;
  overflow-x: auto;
  flex: 1;
  scrollbar-width: none;
  &::-webkit-scrollbar { display: none; height: 0; }
}
.picker-thumb {
  appearance: none;
  position: relative;
  flex: 0 0 auto;
  /* Whole cards at either end, including the space reserved for arrows. */
  width: calc((100% - 1.2em) / 4);
  aspect-ratio: 16 / 9;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--panel-2);
  cursor: pointer;
  opacity: 0.45;
  transition: opacity 120ms ease;
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  &:hover {
    opacity: 0.8;
  }
  &.focus-visible {
    opacity: 1;
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  &.active {
    opacity: 1;
  }
  &.active::after {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    height: 2px;
    background: #fff;
  }
  .picker-name {
    display: block;
    padding: 0.35em;
    color: #fff;
    font-size: 0.6em;
    font-weight: 700;
    line-height: 1.15;
    text-align: left;
    overflow: hidden;
  }
}

.actions-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(14.5em, 1fr));
  gap: var(--space-2);
}

/* Function tile: house .row look with a game-icon badge */
.computer-function-tile {
  $rad: var(--radius-panel);

  position: relative;
  display: flex;
  align-items: center;
  gap: 0.7em;
  width: 100%;
  min-width: 0;
  min-height: 3.1em;
  padding: 0.6em 0.8em;
  border: 0;
  border-radius: $rad;
  background: var(--panel);
  color: #fff;
  cursor: pointer;
  transition: transform 120ms ease-out, opacity 120ms ease-out;

  .icon {
    flex: 0 0 auto;
    width: 1.3em;
    font-size: 1.3em;
    line-height: 1;
    text-align: center;
    color: var(--faint);
    transition: color 120ms ease;
  }
  .label {
    flex: 1 1 auto;
    min-width: 0;
    padding-top: 0.12em; /* Overpass sits high at line-height 1.2 */
    font-size: 1.02em;
    font-weight: 700;
    line-height: 1.2;
    text-align: left;
    overflow-wrap: anywhere;
  }
  .lock {
    flex: 0 0 auto;
    font-size: 1em;
    color: var(--faint);
  }

  // controller / keyboard focus: the house ring instead of the game's ::before frame
  @include house-focus;

  &:hover,
  &:focus {
    background: var(--panel-2);
    .icon {
      color: #fff;
    }
  }
  &:active:not(.action-disabled) {
    transform: translateY(1px);
  }
}

/* Disabled: dim + padlock; same colour family, still focusable so the reason shows */
.computer-function-tile.action-disabled {
  opacity: 0.45;
  cursor: default !important;
  &:hover,
  &:focus {
    opacity: 0.6;
  }
}

/* Reason hint under a list (house .notice) */
.disable-reason {
  display: flex;
  align-items: center;
  gap: 0.5em;
  margin: 0;
  padding: 0.65em 0.85em 0.5em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: var(--muted);
  font-size: 0.92em;
  font-weight: 600;
  line-height: 1.35;
  animation: reason-in 160ms ease-out;
  .disable-icon {
    flex: 0 0 auto;
    font-size: 1.15em;
    color: var(--faint);
    transform: translateY(-0.08em);
  }
}
@keyframes reason-in {
  from {
    opacity: 0;
    transform: translateY(0.25em);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

/* Empty garage (house .empty) */
.no-vehicle-container {
  display: grid;
  justify-items: center;
  gap: var(--space-2);
  padding: 1.2em 1em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  text-align: center;
  color: var(--muted);
  .empty-badge {
    display: inline-grid;
    place-items: center;
    width: 1.9em;
    height: 1.9em;
    font-size: 1.35em;
    line-height: 1;
    border-radius: 50%;
    background: var(--panel-2);
    color: var(--faint);
  }
  > span {
    color: #fff;
    font-size: 1.1em;
    font-weight: 800;
  }
  > p {
    margin: 0;
    max-width: 26em;
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.4;
  }
}
</style>
