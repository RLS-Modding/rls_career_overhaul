<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <ComputerWrapper title="Engine Packages" @back="close">
    <ComputerPanel class="engine-panel rls-house" v-bng-blur="1">
      <div class="engine-body">
        <!-- package detail: every part in the package with its condition, mileage and value -->
        <section v-if="detailPkg" class="pkg-detail">
          <div class="detail-top">
            <HouseButton compact variant="quiet" :icon="icons.arrowSmallLeft" @click="closeDetail">Packages</HouseButton>
          </div>

          <div class="detail-hero">
            <div class="pkg-photo">
              <img v-if="thumbUrl(detailPkg)" :src="thumbUrl(detailPkg)" alt="" @error="thumbnailFailed[packageImageKey(detailPkg)] = true" />
              <BngIcon v-else class="pkg-photo-glyph" :type="icons.engine" />
              <span class="photo-tag" :class="statusTone(detailPkg)">{{ statusLabel(detailPkg) }}</span>
              <span v-if="detailPkg.certification" class="photo-tag right" :class="certificationTone(detailPkg)">{{ certificationLabel(detailPkg) }}</span>
            </div>
            <div class="detail-summary">
              <div class="pkg-head">
                <div class="pkg-title">
                  <strong class="pkg-name">{{ detailPkg.name }}</strong>
                  <span class="hint">{{ detailPkg.installedVehicleName || detailPkg.rootEngineNiceName }}</span>
                </div>
                <strong v-if="detailPkg.saleValue != null" class="pkg-value">{{ formatMoney(detailPkg.saleValue) }}</strong>
              </div>
              <dl class="detail-facts">
                <div><dt>Parts</dt><dd>{{ detailPkg.partCount }}</dd></div>
                <div :class="{ warn: conditionPercent(detailPkg) < 75, bad: conditionPercent(detailPkg) < 50 }">
                  <dt>Condition</dt><dd>{{ conditionPercent(detailPkg) }}%</dd>
                </div>
                <div><dt>Mileage</dt><dd>{{ formatDistance(detailPkg.odometer) }}</dd></div>
                <div v-if="detailPkg.tuningCount"><dt>Tuning</dt><dd>{{ detailPkg.tuningCount }} saved</dd></div>
              </dl>
              <p v-if="detailPkg.certification" class="pkg-line" :class="certificationTone(detailPkg)">{{ certificationLine(detailPkg) }}</p>
              <p v-if="detailPkg.status === 'stored' && !data.browseOnly" class="pkg-line" :class="detailPkg.compatible ? 'ok' : 'bad'">
                {{ detailPkg.compatible ? `Fits ${data.currentVehicleName || "this vehicle"}` : detailPkg.compatibilityReason || "Does not fit this vehicle" }}
              </p>
            </div>
          </div>

          <div class="detail-parts">
            <div class="parts-head">
              <span class="caption">Part</span>
              <span class="caption num">Condition</span>
              <span class="caption num">Mileage</span>
              <span class="caption num">Value</span>
            </div>
            <p v-if="detailLoading" class="hint parts-note">Loading parts…</p>
            <p v-else-if="!detailParts.length" class="hint parts-note">No part details available.</p>
            <!-- read-only rows: .force lets the right stick scroll them while focus sits on the back button -->
            <ul v-else class="part-rows scroll" v-bng-ui-nav-scroll.force>
              <li
                v-for="part in detailParts"
                :key="`${part.slotPath}${part.name}`"
                class="part-row"
                :class="{ missing: part.missing, root: part.depth === 0 }"
                :style="{ '--depth': Math.min(part.depth || 0, 6) }">
                <span class="part-name">{{ part.niceName || part.name }}</span>
                <template v-if="part.missing">
                  <span class="part-missing">Missing</span>
                </template>
                <template v-else>
                  <span class="part-cond num" :class="partTone(part)">
                    <span class="cond-bar"><span :style="{ transform: `scaleX(${partCondition(part) / 100})` }" /></span>
                    {{ partCondition(part) }}%
                  </span>
                  <span class="num">{{ formatDistance(part.odometer) }}</span>
                  <span class="num money">{{ formatMoney(part.value) }}</span>
                </template>
              </li>
            </ul>
          </div>
        </section>

        <template v-else>
        <header class="ep-head">
          <span class="hint" v-if="!data.browseOnly">For {{ data.currentVehicleName || "the selected garage vehicle" }}</span>
          <span class="hint" v-else>Browsing. Select a spawned garage vehicle to package, store or install.</span>
          <!-- focusable so a pad can read it: the tooltip shows on focus as well as hover -->
          <button type="button" class="hint help" bng-nav-item v-bng-tooltip:bottom="HELP_TEXT">What do these mean?</button>
        </header>

        <p v-if="message" class="notice" :class="message.success ? 'ok' : 'bad'">{{ message.message }}</p>
        <p v-if="data.busy" class="notice">Updating engine package…</p>

        <div class="engine-list scroll" v-bng-ui-nav-scroll @focusin="rememberFocus">
          <!-- package the engine that is in the car now -->
          <div v-if="!data.currentPackageId && data.hasInstalledEngine" class="create-block">
            <div class="create-copy">
              <strong>Package the installed engine</strong>
              <span class="hint">It stays installed until you swap it.</span>
            </div>
            <div class="create-row">
              <input
                v-model="createName"
                class="field"
                type="text"
                placeholder="Package name (optional)"
                spellcheck="false"
                :disabled="data.busy"
                v-bng-text-input
                @focus="onInputFocus"
                @blur="onInputBlur"
                @keydown.stop="handleCreateKeydown" />
              <HouseButton variant="primary" :disabled="data.busy" :bng-scoped-nav-autofocus="entryFocused ? undefined : true" @click="createPackage">Package engine</HouseButton>
            </div>
          </div>
          <p v-else-if="data.currentPackageId" class="hint">
            The installed engine is already a package. Installing another one stores it automatically.
          </p>
          <p v-else-if="!data.hasInstalledEngine && !data.browseOnly" class="notice">
            No engine is installed. Install a stored package below, or build one in Part Customization.
          </p>

          <div
            v-for="(pkg, pkgIndex) in data.packages"
            :key="pkg.id"
            :data-pkg-id="pkg.id"
            class="package-card"
            :class="{ selected: pkg.id === data.currentPackageId }">
            <div class="pkg-photo clickable" title="View parts" @click="openDetail(pkg)">
              <img v-if="thumbUrl(pkg)" :src="thumbUrl(pkg)" alt="" @error="thumbnailFailed[packageImageKey(pkg)] = true" />
              <BngIcon v-else class="pkg-photo-glyph" :type="icons.engine" />
              <span class="photo-tag" :class="statusTone(pkg)">{{ statusLabel(pkg) }}</span>
              <span v-if="pkg.certification" class="photo-tag right" :class="certificationTone(pkg)">{{ certificationLabel(pkg) }}</span>
            </div>

            <div class="pkg-info">
              <div class="pkg-head">
                <div class="pkg-title">
                  <strong class="pkg-name">{{ pkg.name }}</strong>
                  <span class="hint">{{ pkg.installedVehicleName || pkg.rootEngineNiceName }}</span>
                </div>
                <strong v-if="pkg.saleValue != null" class="pkg-value">{{ formatMoney(pkg.saleValue) }}</strong>
              </div>

              <div v-if="renameId === pkg.id" class="rename-row">
                <input
                  v-model="renameName"
                  class="field"
                  type="text"
                  placeholder="Package name"
                  spellcheck="false"
                  :disabled="data.busy"
                  v-bng-text-input
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  @keydown.stop="handleRenameKeydown($event, pkg)" />
                <HouseButton compact variant="quiet" :disabled="data.busy" @click="cancelRename">Cancel</HouseButton>
                <HouseButton compact :disabled="data.busy || !renameName.trim()" @click="commitRename(pkg)">Save</HouseButton>
              </div>

              <template v-else>
                <div class="pkg-specs">
                  <button
                    type="button"
                    class="spec spec-link act-detail"
                    bng-nav-item
                    :bng-scoped-nav-autofocus="!entryFocused && pkgIndex === 0 && !showCreate ? true : undefined"
                    @click="openDetail(pkg)">
                    <BngIcon class="spec-icon" :type="icons.engine" />{{ pkg.partCount }} parts<BngIcon class="spec-chevron" :type="icons.arrowSmallRight" />
                  </button>
                  <span class="spec" :class="{ warn: conditionPercent(pkg) < 75, bad: conditionPercent(pkg) < 50 }">
                    <BngIcon class="spec-icon" :type="icons.wrench" />{{ conditionPercent(pkg) }}% condition
                  </span>
                  <span class="spec"><BngIcon class="spec-icon" :type="icons.odometer" />{{ formatDistance(pkg.odometer) }}</span>
                </div>

                <p v-if="pkg.status === 'stored' && !data.browseOnly" class="pkg-line" :class="pkg.compatible ? 'ok' : 'bad'">
                  {{ pkg.compatible ? `Fits ${data.currentVehicleName || "this vehicle"}` : pkg.compatibilityReason || "Does not fit this vehicle" }}
                </p>
                <p v-else-if="pkg.status === 'incomplete'" class="pkg-line bad">
                  Can't be installed: some of its parts are missing.
                </p>
                <p v-else-if="pkg.certification" class="pkg-line" :class="certificationTone(pkg)">{{ certificationLine(pkg) }}</p>
              </template>

              <div v-if="confirmDismantleId !== pkg.id && confirmSellId !== pkg.id && renameId !== pkg.id" class="pkg-actions">
                <HouseButton v-if="pkg.status === 'stored'" class="act-install" compact :disabled="!pkg.canInstall || data.busy" @click="installPackage(pkg)">Install</HouseButton>
                <HouseButton v-if="pkg.canStore" class="act-store" compact :disabled="data.busy" @click="storePackage(pkg)">Store</HouseButton>
                <HouseButton class="act-rename" compact variant="quiet" :disabled="data.busy" @click="startRename(pkg)">Rename</HouseButton>
                <HouseButton v-if="pkg.status === 'stored'" class="act-sell" compact variant="quiet" :disabled="data.busy || !pkg.canSell" @click="askSell(pkg)">Sell</HouseButton>
                <HouseButton class="act-dismantle" compact variant="quiet-danger" :disabled="data.busy" @click="askDismantle(pkg)">Dismantle</HouseButton>
              </div>

              <div v-else-if="confirmDismantleId === pkg.id" class="confirm">
                <p class="notice bad">Dismantle it? Its parts go back to My Parts.</p>
                <div class="pkg-actions">
                  <HouseButton compact variant="quiet" :disabled="data.busy" @click="cancelDismantle">Cancel</HouseButton>
                  <HouseButton compact variant="danger" :disabled="data.busy" @click="dismantlePackage(pkg)">Dismantle</HouseButton>
                </div>
              </div>
              <div v-else-if="confirmSellId === pkg.id" class="confirm">
                <p class="notice warn">Sell the whole package for {{ formatMoney(pkg.saleValue) }}? All its parts go with it.</p>
                <div class="pkg-actions">
                  <HouseButton compact variant="quiet" :disabled="data.busy" @click="cancelSell">Cancel</HouseButton>
                  <HouseButton
                    compact
                    variant="primary"
                    :disabled="data.busy || !pkg.canSell"
                    v-bng-on-ui-nav:ok.asMouse.focusRequired
                    v-bng-click="{ holdCallback: () => sellPackage(pkg), holdDelay: 1000, repeatInterval: 0 }">
                    Hold to sell
                  </HouseButton>
                </div>
              </div>
            </div>
          </div>

          <p v-if="!data.packages.length && !data.busy" class="hint empty-line">
            No engine packages yet. Select a spawned vehicle to package its engine.
          </p>
        </div>
        </template>
      </div>
    </ComputerPanel>
  </ComputerWrapper>
</template>

<script setup>
import { reportUiFailure } from "../utils/safeLua"

import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../components/house/index.js"
import { vBngBlur, vBngClick, vBngOnUiNav, vBngTextInput, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import { formatOdometer } from "../utils/units"
import ComputerPanel from "../components/ComputerPanel.vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useScreenEntry, refocusIfLost } from "../composables/useScreenEntryFocus"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const HELP_TEXT =
  "Mechanical condition is the average remaining integrity of every included part; 100% means unworn. A stress test reveals the package's measured output and declared torque limit before installation. Certification performed by an Engine Works business also creates a production blueprint."

const { events, lua, units } = useBridge()

const data = ref({
  busy: false,
  currentInventoryId: null,
  currentPackageId: null,
  hasInstalledEngine: false,
  packages: [],
})
const message = ref(null)
const createName = ref("")
const renameId = ref(null)
const renameName = ref("")
const confirmDismantleId = ref(null)
const confirmSellId = ref(null)
const thumbnailFailed = ref({})

let messageTimer = null
let inputFocused = false

function onInputFocus() {
  inputFocused = true
}

function onInputBlur() {
  inputFocused = false
}

function handleCreateKeydown(event) {
  if (event.key !== "Enter") return
  event.preventDefault()
  createPackage()
}

function handleRenameKeydown(event, pkg) {
  if (event.key === "Enter") {
    event.preventDefault()
    commitRename(pkg)
  } else if (event.key === "Escape") {
    event.preventDefault()
    cancelRename()
  }
}

function updateData(payload) {
  const incomingPackages = Array.isArray(payload?.packages) ? payload.packages : []
  const packageIds = new Set()
  const packages = incomingPackages.map((incoming) => {
    const pkg = { ...(incoming || {}) }
    const id = String(pkg.id || "")
    if (id) packageIds.add(id)
    return pkg
  })
  if (detailId.value) {
    // the open package went away (sold, dismantled, merged): leave the detail page for real, so the
    // next Back exits the screen instead of clearing state nobody can see
    if (packageIds.has(detailId.value)) loadDetailParts()
    else resetDetail()
  }
  data.value = {
    busy: false,
    currentInventoryId: null,
    currentVehicleName: null,
    browseOnly: false,
    currentPackageId: null,
    hasInstalledEngine: false,
    ...(payload || {}),
    packages,
  }
}

function handleResult(payload) {
  message.value = payload || null
  if (payload?.success) {
    createName.value = ""
    renameId.value = null
    renameName.value = ""
    confirmDismantleId.value = null
    confirmSellId.value = null
    clearTimeout(messageTimer)
    messageTimer = setTimeout(() => {
      message.value = null
    }, 3500)
  }
}

async function requestData() {
  const result = await lua.overhaul_career_parts_engines_enginePackages.requestData()
  if (result) updateData(result)
}

// detail page: the package comes from the live list (so it updates and closes if the package goes away);
// its parts come from Lua getPackageDetails
const detailId = ref(null)
const detailParts = ref([])
const detailLoading = ref(false)
const detailPkg = computed(() => (detailId.value ? data.value.packages.find(p => p.id === detailId.value) || null : null))

// request generation: every open, close and reload bumps it, and a response only lands if it is still
// the newest one. Comparing ids alone let an old reply overwrite a fresh one after closing and
// reopening the same package.
let detailRequest = 0

function resetDetail() {
  detailRequest++
  detailId.value = null
  detailParts.value = []
  detailLoading.value = false
}

async function loadDetailParts() {
  const id = detailId.value
  if (!id) return
  const request = ++detailRequest
  try {
    const details = await lua.overhaul_career_parts_engines_enginePackages.getPackageDetails(id)
    if (request !== detailRequest) return
    const parts = details?.parts
    detailParts.value = Array.isArray(parts) ? parts : parts && typeof parts === "object" ? Object.values(parts) : []
  } catch (e) {
    reportUiFailure(e, "[enginePackages] getPackageDetails failed (EnginePackages)")
    if (request === detailRequest) detailParts.value = []
  } finally {
    if (request === detailRequest) detailLoading.value = false
  }
}

function openDetail(pkg) {
  if (!pkg?.id) return
  cancelRename()
  detailId.value = pkg.id
  detailParts.value = []
  detailLoading.value = true
  loadDetailParts()
}

function closeDetail() {
  resetDetail()
}

function partCondition(part) {
  return Math.max(0, Math.min(100, Math.round(Number(part.integrity ?? 1) * 100)))
}

function partTone(part) {
  const c = partCondition(part)
  return c < 50 ? "bad" : c < 75 ? "warn" : ""
}

async function close() {
  // Back / Escape unwinds one level: an open confirm or rename row, then the detail page, then the screen
  if (confirmSellId.value || confirmDismantleId.value || renameId.value) {
    cancelSell()
    cancelDismantle()
    cancelRename()
    return
  }
  if (detailId.value) {
    closeDetail()
    return
  }
  await lua.overhaul_career_parts_engines_enginePackages.closeMenu()
}

function createPackage() {
  if (data.value.busy || data.value.currentPackageId) return
  lua.overhaul_career_parts_engines_enginePackages.createFromCurrent(createName.value)
}

function startRename(pkg) {
  if (data.value.busy) return
  renameId.value = pkg.id
  renameName.value = pkg.name
  confirmDismantleId.value = null
  confirmSellId.value = null
}

function cancelRename() {
  renameId.value = null
  renameName.value = ""
}

function commitRename(pkg) {
  if (data.value.busy || !renameName.value.trim()) return
  lua.overhaul_career_parts_engines_enginePackages.renamePackage(pkg.id, renameName.value)
}

function installPackage(pkg) {
  if (data.value.busy || !pkg.canInstall) return
  confirmDismantleId.value = null
  lua.overhaul_career_parts_engines_enginePackages.installPackage(pkg.id)
}

function storePackage(pkg) {
  if (data.value.busy || !pkg.canStore) return
  confirmDismantleId.value = null
  lua.overhaul_career_parts_engines_enginePackages.storeInstalledPackage(pkg.id)
}

function askDismantle(pkg) {
  if (data.value.busy) return
  confirmDismantleId.value = pkg.id
  confirmSellId.value = null
  renameId.value = null
}

function cancelDismantle() {
  confirmDismantleId.value = null
}

function dismantlePackage(pkg) {
  if (data.value.busy) return
  lua.overhaul_career_parts_engines_enginePackages.dismantlePackage(pkg.id)
}

function askSell(pkg) {
  if (data.value.busy || !pkg.canSell) return
  confirmSellId.value = pkg.id
  confirmDismantleId.value = null
  renameId.value = null
}

function cancelSell() {
  confirmSellId.value = null
}

function sellPackage(pkg) {
  if (data.value.busy || !pkg.canSell) return
  lua.overhaul_career_parts_engines_enginePackages.sellPackage(pkg.id)
}

function statusLabel(pkg) {
  if (pkg.status === "stored") return "Stored"
  if (pkg.status === "installed") return "Installed"
  return "Incomplete"
}

function statusTone(pkg) {
  if (pkg.status === "installed") return "ok"
  if (pkg.status === "incomplete") return "bad"
  if (pkg.status === "stored" && pkg.compatible === false) return "warn"
  return "unknown"
}

function certificationLabel(pkg) {
  if (pkg.certification?.status === "passed") return "Certified"
  if (pkg.certification?.status === "pending") return "Certifying"
  if (pkg.certification?.status === "failed") return "Failed"
  if (pkg.certification?.status === "unknown") return "Rating unknown"
  return ""
}

function certificationTone(pkg) {
  return pkg.certification?.status || ""
}

function certificationSummary(pkg) {
  if (pkg.certification?.status === "unknown") return certificationLine(pkg)
  if (pkg.certification?.status === "passed") return "Stress test passed — limits verified"
  if (pkg.certification?.status === "failed") return "Stress test failed — declared limit exceeded"
  return "Stress test in progress"
}

function certificationLine(pkg) {
  const c = pkg.certification || {}
  if (c.status === "pending") return "Stress test running"
  if (c.status === "failed" && c.reason) return c.reason
  if (c.status === "unknown") return c.reason || "Rating unknown: this engine mod does not provide a usable torque rating"
  const limits = `${formatPower(c.estimatedSafePower)}, ${formatTorque(c.torqueLimit ?? c.rating)} max`
  return c.status === "failed" ? `Failed stress test: ${limits}` : `Stress-tested: ${limits}`
}

function conditionPercent(pkg) {
  return Math.max(0, Math.min(100, Math.round(Number(pkg.integrity || 0) * 100)))
}

// part odometers are metres; shown in the player's length unit
function formatDistance(metres) {
  return formatOdometer(units, metres)
}

function formatMoney(value) {
  return value == null ? "—" : units.beamBucks(Number(value) || 0)
}

function formatTorque(value) {
  return value == null ? "—" : units.buildString("torque", Number(value) || 0, 0)
}

function formatPower(value) {
  return value == null ? "—" : units.buildString("power", Number(value) || 0, 0)
}

const packageImageKey = pkg => pkg?.thumbnail ? `${pkg.thumbnail}?${pkg.dirtyDate || 0}` : null
function thumbUrl(pkg) {
  const url = packageImageKey(pkg)
  return url && !thumbnailFailed.value[url] ? url : null
}

// Controller: the detail page, confirm rows and rename row are v-if swaps that unmount the focused
// button. Remember which package (and which action) had focus, and put a pad back there afterwards.
const showCreate = computed(() => !data.value.currentPackageId && !!data.value.hasInstalledEngine)
const listFocus = { pkgId: null, act: null }
function rememberFocus(event) {
  const target = event.target
  const card = target?.closest?.(".package-card")
  if (card) listFocus.pkgId = card.dataset.pkgId
  const act = [...(target?.classList || [])].find(c => c.startsWith("act-"))
  if (act) listFocus.act = act
}
function pickFocus() {
  if (detailId.value) return document.querySelector(".pkg-detail .detail-top button")
  const card = listFocus.pkgId && [...document.querySelectorAll(".engine-list .package-card")].find(el => el.dataset.pkgId === listFocus.pkgId)
  if (!card) return document.querySelector(".engine-list button:not([disabled])")
  return (
    card.querySelector(".confirm button:not([disabled]), .rename-row input") ||
    (listFocus.act && card.querySelector("." + listFocus.act + ":not([disabled])")) ||
    card.querySelector(".pkg-actions button:not([disabled]), .act-detail")
  )
}
// opening / closing the detail page or a confirm / rename row moves focus on purpose; a data refresh
// only repairs focus that was lost
// note where focus is just before a swap, without depending on focusin (which a hidden or unfocused
// window never fires)
watch([detailId, renameId, confirmSellId, confirmDismantleId], () => rememberFocus({ target: document.activeElement }), { flush: "pre" })
watch([detailId, renameId, confirmSellId, confirmDismantleId], () => refocusIfLost(pickFocus, { force: true }), { flush: "post" })
watch(() => data.value.packages, () => refocusIfLost(pickFocus), { flush: "post" })

// the autofocus marks are for entry only: the root scope prefers autofocus over the last focused
// item, so leaving them would pull focus back to the top after every swap
const entryFocused = ref(false)
let entryStarted = false
watch(() => data.value.packages, () => {
  if (entryStarted) return
  entryStarted = true
  // mod route: wake the screen scope so the d-pad starts on "Package engine" or the first package
  focusScreenEntry().then(() => setTimeout(() => { entryFocused.value = true }, 600))
}, { flush: "post" })

onMounted(() => {
  events.on("enginePackagesData", updateData)
  events.on("enginePackagesActionResult", handleResult)
  requestData()
})

onBeforeUnmount(() => {
  events.off("enginePackagesData", updateData)
  events.off("enginePackagesActionResult", handleResult)
  clearTimeout(messageTimer)
  if (inputFocused) onInputBlur()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.hint.help { position: relative; }

/* House engine packages. Two classes so these win over ComputerPanel's own root rules. */
.engine-panel.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(94vw, 52em);
  height: min(90vh, 52em);
  display: flex;
  flex-direction: column;
  padding: 0.9em 1em 1em;
  border-radius: var(--radius-control);
  border-bottom: 0;
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  :deep(.panel-content) {
    display: flex;
    flex-direction: column;
    min-height: 0;
    height: 100%;
  }
}
.engine-body {
  display: flex;
  flex-direction: column;
  gap: 0.6em;
  min-height: 0;
  height: 100%;
}
.ep-head {
  display: flex;
  justify-content: space-between;
  gap: 1em;
  .help {
    position: relative;
    appearance: none;
    margin: 0;
    padding: 0;
    border: 0;
    border-radius: 0.2em;
    background: none;
    font: inherit;
    cursor: help;
    text-decoration: underline dotted rgba(255, 255, 255, 0.3);
    text-underline-offset: 0.2em;
    @include house-focus;
  }
}
.engine-list {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 0.55em;
  padding-right: 0.4em;
}

/* ---- package the installed engine */
.create-block {
  display: grid;
  gap: 0.5em;
  padding: 0.85em 0.9em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.create-copy {
  display: grid;
  gap: 0.1em;
  strong {
    font-weight: 800;
  }
}
.create-row,
.rename-row {
  display: flex;
  align-items: center;
  gap: 0.45em;
  .field {
    flex: 1 1 auto;
    min-width: 0;
  }
}

/* ---- a package: photo, then name/value, details, status lines, actions */
.package-card {
  display: grid;
  grid-template-columns: 14.5em minmax(0, 1fr);
  align-items: stretch;
  gap: 1em;
  padding: 0.6em 0.9em 0.6em 0.6em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.selected {
    background: var(--panel-2);
    .pkg-name {
      color: var(--accent-soft);
    }
  }
}
.pkg-photo {
  position: relative;
  align-self: start;
  &.clickable {
    cursor: pointer;
    transition: box-shadow 0.15s ease;
    &:hover {
      box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.25);
    }
  }
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
  .pkg-photo-glyph {
    font-size: 2.6em;
    color: rgba(255, 255, 255, 0.18);
  }
}
.photo-tag {
  position: absolute;
  top: 0.4em;
  left: 0.4em;
  padding: 0.4em 0.5em 0.15em;
  border-radius: var(--radius-pill);
  background: rgba(21, 21, 23, 0.82);
  color: rgba(255, 255, 255, 0.85);
  font-size: 0.7em;
  font-weight: 700;
  line-height: 1;
  &.right {
    left: auto;
    right: 0.4em;
  }
  &.ok,
  &.passed { color: var(--ok-ink); }
  &.warn,
  &.pending,
  &.unknown { color: var(--warn); }
  &.bad,
  &.failed { color: var(--bad); }
}

.pkg-info {
  display: grid;
  gap: 0.4em;
  min-width: 0;
  align-content: space-between;
}
.pkg-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 1em;
}
.pkg-title {
  display: grid;
  gap: 0.1em;
  min-width: 0;
}
/* long package names get two lines before the ellipsis */
.pkg-name {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  overflow-wrap: anywhere;
  font-size: 1.2em;
  font-weight: 800;
  line-height: 1.15;
}
.pkg-value {
  flex: 0 0 auto;
  padding-top: 0.1em;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.pkg-specs {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25em 1.1em;
}
.spec {
  display: flex;
  align-items: center;
  gap: 0.35em;
  white-space: nowrap;
  color: var(--muted);
  font-size: 0.86em;
  font-weight: 600;
  .spec-icon {
    width: auto;
    font-size: 1.15em;
    text-align: center;
    color: var(--faint);
  }
  &.warn { color: var(--warn); }
  &.bad { color: var(--bad); }
}
// "N parts" opens the detail page
.spec-link {
  position: relative;
  appearance: none;
  border: 0;
  background: none;
  padding: 0;
  font: inherit;
  font-size: 0.86em;
  cursor: pointer;
  color: #fff;
  .spec-chevron {
    font-size: 0.9em;
    color: var(--faint);
    transition: transform 0.15s ease;
  }
  &:hover .spec-chevron,
  &.focus-visible .spec-chevron {
    transform: translateX(0.15em);
    color: #fff;
  }
  border-radius: var(--radius-thumb, 0.3em);
  @include house-focus;
}
.pkg-line {
  margin: 0;
  font-size: 0.86em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  &.ok,
  &.passed { color: var(--ok-ink); }
  &.pending,
  &.unknown { color: var(--warn); }
  &.bad,
  &.failed { color: var(--bad); }
}
.pkg-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35em;
}
.confirm {
  display: grid;
  gap: 0.4em;
}
.empty-line {
  padding: 0.6em 0.2em;
}

/* ---- package detail */
.pkg-detail {
  display: flex;
  flex-direction: column;
  gap: 0.8em;
  flex: 1 1 auto;
  min-height: 0;
}
.detail-top {
  display: flex;
}
.detail-hero {
  display: grid;
  grid-template-columns: 19em minmax(0, 1fr);
  gap: 1.1em;
  align-items: stretch;
}
.detail-summary {
  display: grid;
  align-content: start;
  gap: 0.6em;
  min-width: 0;
  .pkg-name {
    font-size: 1.4em;
  }
}
.detail-facts {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, auto));
  justify-content: start;
  gap: 0.2em 1.6em;
  margin: 0;
  dt {
    font-size: 0.7em;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--faint);
  }
  dd {
    margin: 0;
    font-size: 1.1em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
  }
  .warn dd { color: var(--warn); }
  .bad dd { color: var(--bad); }
}
.detail-parts {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  overflow: hidden;
}
.parts-head,
.part-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 8em 6.5em 6.5em;
  align-items: center;
  gap: 0.8em;
  padding: 0 0.9em;
}
.parts-head {
  padding-top: 0.6em;
  padding-bottom: 0.45em;
  border-bottom: 1px solid var(--line);
  .num { text-align: right; }
}
.parts-note {
  padding: 0.8em 0.9em;
}
.part-rows {
  list-style: none;
  margin: 0;
  padding: 0.2em 0 0.4em;
  overflow-y: auto;
  min-height: 0;
}
.part-row {
  min-height: 2.1em;
  font-size: 0.9em;
  &:nth-child(even) {
    background: rgba(255, 255, 255, 0.025);
  }
  .num {
    text-align: right;
    color: var(--muted);
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .money {
    color: var(--money);
  }
  &.root .part-name {
    font-weight: 800;
    color: #fff;
  }
  &.missing .part-name {
    color: var(--bad);
  }
}
// the part tree: each level steps in, with a faint guide
.part-name {
  position: relative;
  padding-left: calc(var(--depth, 0) * 0.9em);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.86);
}
.part-cond {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 0.45em;
  &.warn { color: var(--warn); }
  &.bad { color: var(--bad); }
}
.cond-bar {
  position: relative;
  width: 3em;
  height: 0.3em;
  border-radius: 1em;
  overflow: hidden;
  background: rgba(255, 255, 255, 0.1);
  > span {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    background: rgba(255, 255, 255, 0.55);
    transform-origin: left center;
  }
  .warn & > span { background: var(--warn); }
  .bad & > span { background: var(--bad); }
}
.part-missing {
  grid-column: 2 / -1;
  justify-self: end;
  color: var(--bad);
  font-weight: 700;
}
</style>
