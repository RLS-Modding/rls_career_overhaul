<template>
  <ComputerWrapper
    :title="$translate.instant('ui.career.shared.pathTuning')"
    @back="confirmCancel">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: 'career-tuning', preferAutoFocus: true, canDeactivate: tuningBack }"
      class="tuning-card rls-house"
      ref="elCard"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      v-bng-on-ui-nav:tab_l="previousVehicle" v-bng-on-ui-nav:tab_r="nextVehicle"
      :active="isTuningActive">
      <!-- no inner heading: the page title already says Tuning (context still switches to the cart) -->
      <div v-if="isTuningTent && activeVehicle" class="tuning-vehicle-selector">
        <HouseButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          compact
          variant="quiet"
          :icon="icons.arrowLargeLeft"
          :nav-item="false"
          :disabled="switchingVehicle || savedTuneApplyInProgress || exitInProgress"
          bng-no-nav="true"
          @click="cycleVehicle(-1)">
          <BngBinding ui-event="tab_l" controller />
        </HouseButton>
        <div class="vehicle-selector-label">
          <span class="vehicle-selector-caption">Tuning vehicle</span>
          <strong>{{ switchingVehicle ? "Switching vehicle…" : activeVehicle.niceName }}</strong>
          <span v-if="switchError" class="vehicle-selector-error">{{ switchError }}</span>
        </div>
        <HouseButton
          v-if="showVehicleSelectorButtons"
          class="vehicle-selector-button"
          compact
          variant="quiet"
          :icon="icons.arrowLargeRight"
          :nav-item="false"
          :disabled="switchingVehicle || savedTuneApplyInProgress || exitInProgress"
          bng-no-nav="true"
          @click="cycleVehicle(1)">
          <BngBinding ui-event="tab_r" controller />
        </HouseButton>
      </div>
      <Tuning
        ref="tuningComponentRef"
        :class="{ 'vehicle-switching': switchingVehicle || savedTuneApplyInProgress }"
        :button-target="elCard && elCard.buttonsContainer"
        :close-button="false"
        house
        allow-context-nav>
        <template #before-sliders>
          <!-- house .fold: header toggles the list, Save sits beside it; each tune is a .line -->
          <section class="rls-house fold saved-tunes" :class="{ open: !savedTunesCollapsed }" aria-labelledby="saved-tunes-heading">
            <div class="saved-tunes-header">
              <button
                id="saved-tunes-heading"
                type="button"
                class="fold-summary saved-tunes-toggle"
                :aria-expanded="!savedTunesCollapsed"
                @click="savedTunesCollapsed = !savedTunesCollapsed">
                <svg class="fold-chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>
                <strong class="saved-tunes-title">Saved tunes</strong>
                <span class="pill saved-tunes-count">{{ savedTunes.length }}</span>
              </button>
              <HouseButton class="save-btn" compact :icon="icons.floppyDisk" :disabled="savedTuneApplyInProgress || savedTunesReadOnly" title="Save the current settings as a tune" @click="saveCurrentTune()">Save</HouseButton>
            </div>

            <div v-if="!savedTunesCollapsed" class="fold-body">
              <p v-if="savedTunesError" class="notice bad">{{ savedTunesError }}</p>
              <p v-else-if="savedTunes.length === 0" class="muted saved-tunes-none">No tunes saved for this vehicle model.</p>
              <div v-else class="lines saved-tunes-list">
                <div v-for="tune in savedTunes" :key="tune.id" class="line saved-tune">
                  <span class="row-copy">
                    <strong>{{ tune.name }}</strong>
                    <span>{{ tune.variableCount }} {{ tune.variableCount === 1 ? "setting" : "settings" }}</span>
                  </span>
                  <span class="saved-tune-actions">
                    <HouseButton compact :disabled="savedTuneApplyInProgress" @click="applySavedTune(tune)">Apply</HouseButton>
                    <HouseButton compact variant="quiet-danger" :disabled="savedTuneApplyInProgress || savedTunesReadOnly" @click="deleteSavedTune(tune)">Delete</HouseButton>
                  </span>
                </div>
              </div>
              <p v-if="savedTuneApplyInProgress" class="muted saved-tunes-busy">Loading tune preview…</p>
            </div>
          </section>
        </template>
      </Tuning>
      <template #footer></template>
    </ComputerPanel>

    <template #side>
      <ShoppingCart
        :class="{ 'saved-tune-busy': savedTuneApplyInProgress }"
        v-bng-scoped-nav="{ scopeId: 'career-tuning-cart' }"
        :active="isCartActive"
        :cart-data="cartData"
        :player-money="tuningStore.shoppingData.playerMoney"
        :confirm-button-text="$translate.instant('ui.career.shared.confirm')"
        v-bng-on-ui-nav:context="switchToTuning"
        @apply="applyShopping"
        @cancel="confirmCancel"
        @remove-item="removeCartItem" />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { useScreenEntry } from "../composables/useScreenEntryFocus"
import { reportUiFailure } from "../utils/safeLua"

import { useRouteReady } from "@/services/routeReadiness"
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from "vue"
import { BngBinding, ACCENTS, icons } from "@/common/components/base"
import { vBngBlur, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { lua, useBridge } from "@/bridge"
import { useScopedNav } from "@/services/scopedNav/api"
import { $translate } from "@/services/translation"
import { useUINavBlocker } from "@/services/uiNavTracker"

import { useTuningStore } from "../../vehicleConfig/stores/tuningStore"

import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import Tuning from "../../vehicleConfig/components/Tuning.vue"
import ShoppingCart from "../components/ShoppingCart.vue"
import { refocusIfLost } from "../composables/useScreenEntryFocus"
import { HouseButton, openHousePrompt, openHouseConfirmation, openHouseMessage, openHouseProgress } from "../components/house/index.js"

const enterScreen = useScreenEntry()

const tuningStore = useTuningStore()
const { events } = useBridge()

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["context"])

const { switchScope, current } = useScopedNav()

const isCartActive = computed(() => current.value?.id === "career-tuning-cart")
const isTuningActive = computed(() => current.value?.id === "career-tuning")

const switchToCart = () => switchScope("career-tuning-cart")
const switchToTuning = () => switchScope("career-tuning")

// BACK from the tuning scope must run the cancel/confirm flow instead of letting
// the route back bypass tuning cleanup. Returning false stops scope deactivation.
const tuningBack = () => {
  confirmCancel()
  return false
}

const CANCEL_MESSAGE = $translate.instant("ui.career.shared.cancelShoppingMessage")
const CONFIRM_BUTTONS = [
  { label: $translate.instant("ui.common.no"), value: false, extras: { cancel: true, outsideCancel: false, accent: ACCENTS.secondary } },
  { label: $translate.instant("ui.common.yes"), value: true, extras: { confirm: true, destructive: true } },
]

const SWITCH_VEHICLE_MESSAGE = "Switch tuning vehicles?<br />Any unpurchased tuning changes on this vehicle will be discarded."
const exitInProgress = ref(false)
const savedTunes = ref([])
const savedTunesReadOnly = ref(false)
const savedTunesError = ref("")
const savedTuneApplyInProgress = ref(false)
const savedTunesCollapsed = ref(false)

const errorMessages = {
  unreadable_file: "The saved tunes file cannot be read. It was left untouched; saving and deleting are disabled.",
  unsupported_version: "This saved tunes file was created by an unsupported version. It was left untouched.",
  invalid_root: "The saved tunes file is invalid. It was left untouched.",
  invalid_models: "The saved tunes file has an invalid model library. It was left untouched.",
  invalid_model_group: "The saved tunes file has an invalid model entry. It was left untouched.",
  write_failed: "BeamNG could not write the saved tunes file.",
  empty_snapshot: "There are no visible tuning settings to save.",
  vehicle_respawn_failed: "The vehicle could not be reloaded for this tune preview.",
  tune_not_found: "That saved tune is no longer available.",
}

function resultError(result, fallback = "Saved tunes are unavailable.") {
  return errorMessages[result?.reason || result?.error] || fallback
}

// Back can arrive from the panel scope, the route handler and the cart at once: one dialog at a time.
let confirmingExit = false
const confirmCancel = async () => {
  if (confirmingExit || exitInProgress.value || switchingVehicle.value || savedTuneApplyInProgress.value) return
  confirmingExit = true
  let confirmed
  try {
    confirmed = !(tuningStore.shoppingData.shoppingCart && tuningStore.shoppingData.shoppingCart.items.length) || await openHouseConfirmation(null, CANCEL_MESSAGE, CONFIRM_BUTTONS)
  } finally {
    confirmingExit = false
  }
  if (confirmed) {
    exitInProgress.value = true
    // The backend closes the route after any applied preview has been restored.
    // Show progress immediately without adding a fixed delay to the exit path.
    openHouseProgress("", $translate.instant("ui.career.shared.pathTuning"), { indeterminate: true, cancellable: false, timeout: 3 })
    cancelShopping()
  }
}

const cartData = computed(() => {
  const cart = tuningStore.shoppingData ? tuningStore.shoppingData.shoppingCart : null
  const res = { total: 0, taxes: 0, items: [] }
  if (cart) {
    res.total = cart.total
    res.taxes = cart.taxes
    if (Array.isArray(cart.items)) {
      res.items = cart.items.map(item => ({
        type: item.type || (item.level === 1 && "item"),
        level: item.level,
        name: item.title,
        price: item.price,
        priceHide: !item.price,
        removeShow: !!item.varName,
        varName: item.varName,
      }))
    }
  }
  return res
})

const elCard = ref()
const tuningComponentRef = ref(null)

const tuningSession = ref({ vehicles: [], activeInventoryId: null, isTuningTent: false })
const switchingVehicle = ref(false)
const switchError = ref("")

const isTuningTent = computed(() => tuningSession.value.isTuningTent === true)
const tuningVehicles = computed(() => Array.isArray(tuningSession.value.vehicles) ? tuningSession.value.vehicles : [])
const activeVehicleIndex = computed(() => tuningVehicles.value.findIndex(vehicle =>
  String(vehicle.inventoryId) === String(tuningSession.value.activeInventoryId)
))
const activeVehicle = computed(() => tuningVehicles.value[activeVehicleIndex.value] || tuningVehicles.value[0] || null)
const showVehicleSelectorButtons = computed(() => tuningVehicles.value.length > 1)

async function refreshSavedTunes() {
  const result = await lua.overhaul_career_parts_tuning.getSavedTunes()
  if (!result?.success) {
    savedTunes.value = []
    savedTunesReadOnly.value = true
    savedTunesError.value = resultError(result)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : []
  savedTunesReadOnly.value = result.readOnly === true
  savedTunesError.value = result.readOnly ? resultError(result) : ""
}

async function saveCurrentTune() {
  if (savedTuneApplyInProgress.value || savedTunesReadOnly.value) return
  const name = await openHousePrompt("Give it a name you'll recognise in the Saved tunes list.", "Save tune", {
    // prefilled so OK works on a pad without an on-screen keyboard
    defaultValue: nextTuneName(),
    placeholder: "e.g. Track day",
    maxLength: 40,
    validate: value => typeof value === "string" && Array.from(value.trim()).length >= 1 && Array.from(value.trim()).length <= 40,
    errorMessage: "Enter a name (up to 40 characters).",
  }).catch(() => false)
  if (typeof name !== "string") return
  const snapshot = tuningComponentRef.value?.getVisibleTuneSnapshot?.()
  if (!snapshot) {
    await openHouseMessage("Saved Tunes", "The visible tuning settings could not be read.")
    return
  }

  let result = await lua.overhaul_career_parts_tuning.saveTune(name, snapshot, false)
  if (result?.reason === "duplicate_name") {
    const replace = await openHouseConfirmation(
      "Replace Saved Tune?",
      `A tune named <strong>${escapeHtml(result.duplicate?.name || name.trim())}</strong> already exists for this model. Replace it?`,
      CONFIRM_BUTTONS)
    if (!replace) return
    result = await lua.overhaul_career_parts_tuning.saveTune(name, snapshot, true)
  }

  if (!result?.success) {
    savedTunesError.value = resultError(result, "The tune could not be saved.")
    await openHouseMessage("Saved Tunes", savedTunesError.value)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : savedTunes.value
  savedTunesError.value = ""
}

function nextTuneName() {
  const taken = new Set(savedTunes.value.map(item => String(item.name || "").trim().toLowerCase()))
  let n = savedTunes.value.length + 1
  while (taken.has(`tune ${n}`)) n++
  return `Tune ${n}`
}

async function deleteSavedTune(tune) {
  if (!tune || savedTuneApplyInProgress.value || savedTunesReadOnly.value) return
  const deletedIndex = savedTunes.value.findIndex(item => item.id === tune.id)
  const confirmed = await openHouseConfirmation(
    "Delete Saved Tune?",
    `Delete <strong>${escapeHtml(tune.name)}</strong>? This cannot be undone.`,
    [{ ...CONFIRM_BUTTONS[0], extras: { destructive: true } }, CONFIRM_BUTTONS[1]])
  if (!confirmed) return
  const result = await lua.overhaul_career_parts_tuning.deleteSavedTune(tune.id)
  if (!result?.success) {
    savedTunesError.value = resultError(result, "The tune could not be deleted.")
    await openHouseMessage("Saved Tunes", savedTunesError.value)
    return
  }
  savedTunes.value = Array.isArray(result.tunes) ? result.tunes : savedTunes.value.filter(item => item.id !== tune.id)
  savedTunesError.value = ""
  // the deleted row took the focused Delete button with it: a pad moves to the tune that took its
  // place (or the one above), else to Save
  refocusIfLost(() => {
    const rows = [...document.querySelectorAll(".saved-tunes .saved-tune")]
    const row = rows[Math.min(Math.max(deletedIndex, 0), rows.length - 1)]
    return row?.querySelector("button:not([disabled])") || document.querySelector(".saved-tunes .save-btn:not([disabled]), .saved-tunes .saved-tunes-toggle")
  }, { force: true })
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;")
}

const skippedReasonLabels = {
  corrupt: "saved value is corrupt",
  missing: "setting is not provided by the installed parts",
  hidden: "setting is hidden in career tuning",
  session_blocked: "setting is not permitted in this session",
  out_of_range: "saved value is outside the installed part's range",
}

async function showSavedTuneResult(data) {
  if (!data?.success) {
    await openHouseMessage("Saved Tunes", resultError(data, "The tune preview could not be loaded."))
    return
  }
  const applied = Number(data.appliedCount) || 0
  const skipped = Number(data.skippedCount) || 0
  let message = `<strong>${escapeHtml(data.name || "Saved tune")}</strong>: ${applied} applied, ${skipped} skipped.`
  if (skipped > 0 && Array.isArray(data.skipped)) {
    message += "<ul>" + data.skipped.map(item =>
      `<li>${escapeHtml(item.label || item.name)} — ${escapeHtml(skippedReasonLabels[item.reason] || item.reason)}</li>`
    ).join("") + "</ul>"
  }
  message += "Review and purchase the cart to make this preview permanent."
  await openHouseMessage("Saved Tune Preview", message)
}

async function applySavedTune(tune) {
  if (!tune || savedTuneApplyInProgress.value || switchingVehicle.value || exitInProgress.value) return
  tuningComponentRef.value?.prepareForExternalReload?.()
  savedTuneApplyInProgress.value = true
  const result = await lua.overhaul_career_parts_tuning.applySavedTune(tune.id)
  if (!result?.success && savedTuneApplyInProgress.value) {
    savedTuneApplyInProgress.value = false
    await openHouseMessage("Saved Tunes", resultError(result, "The tune preview could not be started."))
  }
}

async function onSavedTuneApplyCompleted(data) {
  if (!savedTuneApplyInProgress.value) return
  try {
    await tuningComponentRef.value?.refreshFromBackend?.()
  } catch {
    data = {success: false, reason: "vehicle_tuning_data_unavailable"}
  } finally {
    savedTuneApplyInProgress.value = false
  }
  await showSavedTuneResult(data)
}

function hasUnpurchasedChanges() {
  const cartItems = tuningStore.shoppingData?.shoppingCart?.items
  const exposedDirty = tuningComponentRef.value?.isChanged
  const slidersDirty = typeof exposedDirty === "object" && exposedDirty !== null ? exposedDirty.value : exposedDirty
  return !!(Array.isArray(cartItems) && cartItems.length) || slidersDirty === true
}

async function cycleVehicle(offset) {
  if (!isTuningTent.value || !showVehicleSelectorButtons.value || switchingVehicle.value || savedTuneApplyInProgress.value || exitInProgress.value) return false

  const currentIndex = Math.max(0, activeVehicleIndex.value)
  const nextIndex = (currentIndex + offset + tuningVehicles.value.length) % tuningVehicles.value.length
  const target = tuningVehicles.value[nextIndex]
  if (!target || String(target.inventoryId) === String(tuningSession.value.activeInventoryId)) return false

  if (hasUnpurchasedChanges() && !await openHouseConfirmation(null, SWITCH_VEHICLE_MESSAGE, CONFIRM_BUTTONS)) {
    return false
  }

  switchingVehicle.value = true
  switchError.value = ""
  try {
    const result = await lua.overhaul_career_parts_tuning.switchVehicle(Number(target.inventoryId))
    if (result?.success) return false
  } catch (error) { reportUiFailure(error, "cycle vehicle (TuningMain)") }

  if (switchingVehicle.value) {
    switchingVehicle.value = false
    switchError.value = "That vehicle is no longer available in the tuning area."
  }
  return false
}

async function refreshTuningSession(data = null) {
  const nextSession = data || await lua.overhaul_career_parts_tuning.getTuningSessionData()
  if (nextSession) tuningSession.value = nextSession
}

async function onTuningVehicleChanged(data) {
  if (!data?.success) {
    switchingVehicle.value = false
    switchError.value = "Unable to load tuning data for that vehicle."
    return
  }

  try {
    await refreshTuningSession(data)
    await tuningComponentRef.value?.refreshFromBackend?.()
    await refreshSavedTunes()
  } catch {
    switchError.value = "Unable to load tuning data for that vehicle."
  } finally {
    switchingVehicle.value = false
    // the sliders were rebuilt for the new vehicle, taking the focused one with them: a pad continues
    // on the panel's first item instead of <body>
    refocusIfLost(() => elCard.value?.$el?.querySelector?.('[bng-nav-item]:not([bng-no-nav="true"]):not([disabled]), button:not([disabled]):not([bng-no-nav="true"])'))
  }
}

const applyShopping = () => !savedTuneApplyInProgress.value && lua.overhaul_career_parts_tuning.applyShopping()
const cancelShopping = () => lua.overhaul_career_parts_tuning.cancelShopping()
const removeCartItem = (item) => !savedTuneApplyInProgress.value && lua.overhaul_career_parts_tuning.removeVarFromShoppingCart(item.varName)

// Tuning buckets arrive from Lua after mount. Delay the manual routeMounted ack
// and scope activation until the data is present and rendered so the tuning
// autofocus target lands on a navigable entry.
const previousVehicle = () => { if (isTuningTent.value && showVehicleSelectorButtons.value && !switchingVehicle.value && !savedTuneApplyInProgress.value && !exitInProgress.value) cycleVehicle(-1) }
const nextVehicle = () => { if (isTuningTent.value && showVehicleSelectorButtons.value && !switchingVehicle.value && !savedTuneApplyInProgress.value && !exitInProgress.value) cycleVehicle(1) }

// Lua pushes vehicle switches, saved-tune previews and route-level Back as events.
onMounted(() => {
  events.on("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.on("careerSavedTuneApplyCompleted", onSavedTuneApplyCompleted)
  events.on("tuningRequestExit", confirmCancel)
  refreshTuningSession().catch(() => {
    switchError.value = "Unable to load vehicles in the tuning area."
  })
  refreshSavedTunes().catch(() => {
    savedTunesError.value = "Saved tunes are unavailable."
  })
})

onUnmounted(() => {
  events.off("careerTuningVehicleChanged", onTuningVehicleChanged)
  events.off("careerSavedTuneApplyCompleted", onSavedTuneApplyCompleted)
  events.off("tuningRequestExit", confirmCancel)
})

const isTuningReady = computed(() => Array.isArray(tuningStore.buckets))

useRouteReady({
  onReady: () => enterScreen("career-tuning"),
  async waitUntilReady() {
    if (!isTuningReady.value) {
      await new Promise(resolve => {
        const stop = watch(isTuningReady, ready => {
          if (!ready) return
          stop()
          resolve()
        })
      })
    }
    await nextTick()
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      await new Promise(resolve => window.requestAnimationFrame(() => resolve()))
    }
  },
})

</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Root is ComputerPanel: `.tuning-card.computer-panel` outranks its scoped surface rules.
.tuning-card.computer-panel {
  // ComputerPanel defaults to height: fit-content via --bng-card-height.
  // Without this, Live Wheel Data grows the panel and clips Apply/toggles.
  --bng-card-height: 100%;
  overflow: hidden;
  // resolution-scaled em (like the cart beside it): a 40% width squeezed it to ~285px at 1280x720
  // (tune names cut to "Trai…") and the rem text went tiny at 2560x1440
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(36em, 100%);
  height: 100%;
  max-height: 100%;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.82);
    :deep(.heading::before) {
      background: rgba(255, 255, 255, 0.3);
    }
  }

  &:deep(.panel-content) {
    background-color: rgba(0, 0, 0, 0);
    flex: 1 1 0;
    height: auto;
    min-height: 0;
    max-height: 100%;
    overflow: hidden;
  }

  &:deep(.innerTuningCard) {
    flex: 1 1 0;
    min-height: 0;
    max-height: 100%;
    height: 100%;
    overflow: hidden;
  }
}

// ---- vehicle selector (tuning tent)
.tuning-vehicle-selector {
  flex: 0 0 auto;
  display: flex;
  align-items: stretch;
  min-height: 3.5em;
  margin: 0.35em var(--inset) 0;
  overflow: hidden;
  color: #fff;
  background: var(--panel);
  border-radius: var(--radius-panel);
}

// compact quiet HouseButtons that fill the selector's height
.vehicle-selector-button {
  flex: 0 0 auto;
  min-width: 3em;
  border-radius: 0;
}

.vehicle-selector-label {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 0.15em;
  padding: 0.5em 0.75em 0.4em;
  text-align: center;

  strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 700;
    line-height: 1.2;
  }
}

.vehicle-selector-caption {
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.vehicle-selector-error {
  color: var(--bad);
  font-size: 0.8em;
  font-weight: 600;
}

.vehicle-switching {
  opacity: 0.45;
  pointer-events: none;
}

.saved-tune-busy {
  opacity: 0.45;
  pointer-events: none;
}

// ---- saved tunes panel (inside Tuning's before-sliders slot)
.saved-tunes {
  flex-shrink: 0;
  margin: 0.35em 0 0.5em;
}

.saved-tunes-header {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding-right: 0.6em;
}

.saved-tunes-toggle {
  flex: 1 1 auto;
  min-width: 0;
}

// never squeezed into "Save ..."
.save-btn {
  flex: 0 0 auto;
}

// header: chevron (turns down when open) · title · count pill
.saved-tunes-toggle {
  gap: 0.55em;
  .fold-chevron {
    width: 0.8em;
    height: 0.8em;
    color: var(--faint);
    transition: transform 0.15s ease-out, color 0.12s;
  }
  &:hover .fold-chevron {
    color: #fff;
  }
}
.saved-tunes.open .saved-tunes-toggle .fold-chevron {
  transform: rotate(90deg);
}
.saved-tunes-title {
  line-height: 1.2;
  padding-top: 0.1em; // Overpass sits high
}
.saved-tunes-count {
  font-variant-numeric: tabular-nums;
}

.fold-body {
  gap: 0.45em;
}

.saved-tunes-none,
.saved-tunes-busy {
  font-size: 0.85em;
}

.saved-tune {
  align-items: center;
  padding-top: 0.5em;
  padding-bottom: 0.4em;
}

.saved-tune-actions {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.35em;
}

// Tuning.vue's rows, captions, scrollbar and bottom bar are house-styled by its `house` prop.
</style>
