<template>
  <ComputerWrapper :title="data.shop?.name || 'Engine Shop'" @back="close">
    <ComputerPanel class="retail-panel rls-house" v-bng-blur="1">
      <div class="notices" v-if="notice || data.message || data.vehicle?.engineSwapBlockedReason">
        <p v-if="notice" class="notice" :class="notice.success ? 'ok' : 'bad'">{{ notice.message }}</p>
        <p v-if="data.message" class="notice bad">{{ data.message }}</p>
        <p v-if="data.vehicle?.engineSwapBlockedReason" class="notice bad">{{ data.vehicle.engineSwapBlockedReason }}</p>
      </div>

      <div class="workspace">
        <!-- left: what is for sale, then the shop's own work -->
        <section class="inventory scroll" v-bng-ui-nav-scroll @focusin="rememberFocus">
          <header class="list-head">
            <h2 class="block-title">Available engines</h2>
            <span v-if="data.vehicle" class="hint">Fits {{ data.vehicle.niceName }}</span>
          </header>

          <p v-if="!data.vehicle" class="notice">
            Park your vehicle in the service bay to see engines that fit it. Work orders and stress tests work on foot.
          </p>

          <div v-for="(group, groupIndex) in listingGroups" :key="group.id" class="listing-group">
            <div class="split-head">
              <span class="caption">{{ group.label }}</span>
              <span class="pill">{{ group.listings.length }}</span>
              <hr class="rule" />
            </div>
            <div class="engine-list">
              <button
                v-for="(engine, engineIndex) in group.listings"
                :key="engine.id"
                type="button"
                class="engine-row"
                :data-fk="`engine:${engine.id}`"
                :bng-scoped-nav-autofocus="!entryFocused && groupIndex === 0 && engineIndex === 0 ? true : undefined"
                :class="{ selected: selected?.id === engine.id }"
                @click="select(engine)">
                <span class="engine-top">
                  <strong class="engine-name">{{ engine.name }}</strong>
                  <strong class="engine-price"><MoneyAmount>{{ money(engine.price) }}</MoneyAmount></strong>
                </span>
                <span class="engine-specs">
                  <span class="spec"><BngIcon class="spec-icon" :type="icons.powerGauge03" />{{ power(engine.powerHp) }}</span>
                  <span class="spec"><BngIcon class="spec-icon" :type="icons.odometer" />{{ engine.mileage ? distance(engine.mileage) : "New" }}</span>
                  <span class="spec" :class="reliabilityTone(engine.reliability)">{{ engine.reliability }}</span>
                </span>
              </button>
            </div>
          </div>

          <p v-if="data.vehicle && !data.listings?.length" class="hint empty-line">No complete engine packages fit this vehicle right now.</p>

          <div v-if="data.jobs?.length" class="listing-group">
            <div class="split-head">
              <span class="caption">Shop jobs</span>
              <hr class="rule" />
            </div>
            <div class="sheet">
              <div class="lines">
                <div v-for="job in data.jobs" :key="job.inventoryId" class="line job-line" :data-fk="`job:${job.inventoryId}`">
                  <span class="row-copy">
                    <strong>{{ job.vehicleName }}</strong>
                    <span :class="{ 'is-ready': job.status === 'ready' }">{{ jobStatus(job) }}</span>
                  </span>
                  <span class="line-actions">
                    <HouseButton
                      v-if="job.status === 'installing' || job.status === 'ready'"
                      compact variant="quiet-danger" :disabled="busy" @click="cancelJob(job)">Cancel</HouseButton>
                    <HouseButton
                      v-if="job.status === 'ready'"
                      compact :disabled="busy" @click="retrieveJob(job)">Pick up</HouseButton>
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div v-if="data.certifiablePackages?.length" class="listing-group">
            <div class="split-head">
              <span class="caption">Stress test</span>
              <hr class="rule" />
            </div>
            <p class="hint">Takes 60 s and costs 10% of the package's fresh value. Pausing pauses it.</p>
            <div class="sheet">
              <div class="lines">
                <div v-for="pkg in data.certifiablePackages" :key="pkg.id" class="line cert-line" :data-fk="`cert:${pkg.id}`">
                  <span class="row-copy">
                    <strong>{{ pkg.name }}</strong>
                    <span :class="{ bad: pkg.certification?.status === 'failed' }">{{ certStatus(pkg) }}</span>
                  </span>
                  <HouseButton
                    :key="`${pkg.id}-${pkg.certification?.status || 'stored'}`"
                    compact
                    :disabled="busy || !pkg.canStart"
                    v-bng-on-ui-nav:ok.asMouse.focusRequired
                    v-bng-click="{ holdCallback: () => certify(pkg), holdDelay: 1000, repeatInterval: 0 }">
                    <template v-if="pkg.certification?.status === 'pending' || pkg.certification?.status === 'failed'">{{ stressButtonLabel(pkg) }}</template>
                    <template v-else>Hold to test, <MoneyAmount>{{ money(pkg.estimatedFee) }}</MoneyAmount></template>
                  </HouseButton>
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- right: the selected engine, then what it costs, then buy -->
        <aside class="detail" v-if="selected">
          <div class="detail-scroll scroll" v-bng-ui-nav-scroll.force>
            <header class="detail-head">
              <div class="detail-copy">
                <span class="caption">{{ typeLabel(selected.kind, selected.category) }}</span>
                <h1>{{ selected.name }}</h1>
                <span class="hint">{{ selected.sourceConfigName }}</span>
              </div>
              <strong class="detail-price"><MoneyAmount>{{ money(selected.price) }}</MoneyAmount></strong>
            </header>

            <div class="facts">
              <div class="fact"><span class="fact-key">Power</span><span class="fact-value">{{ power(selected.powerHp) }}</span></div>
              <div class="fact"><span class="fact-key">Mileage</span><span class="fact-value">{{ selected.mileage ? distance(selected.mileage) : "New" }}</span></div>
              <!-- the explanation shows on focus as well as hover, so a pad can read it -->
              <div class="fact has-tip" :class="reliabilityTone(selected.reliability)" bng-nav-item tabindex="0"
                v-bng-tooltip="'Reliability combines mechanical condition (the average remaining integrity of every included part) with the measured stress margin.'">
                <span class="fact-key">Reliability</span><span class="fact-value">{{ selected.reliability }}</span>
              </div>
              <div class="fact"><span class="fact-key">Condition</span><span class="fact-value">{{ condition(selected.integrity) }}</span></div>
              <div class="fact"><span class="fact-key">Max torque</span><span class="fact-value">{{ torque(selected.maxTorqueRatingNm) }}</span></div>
              <div class="fact"><span class="fact-key">Safe power</span><span class="fact-value">{{ power(selected.estimatedSafePowerHp) }}</span></div>
            </div>

            <p class="notice" :class="selected.exceedsStressLimit ? 'bad' : selected.aftermarketUnknown ? 'warn' : 'ok'">
              <template v-if="selected.exceedsStressLimit">Makes more torque than its rated limit. It may damage itself under load.</template>
              <template v-else-if="selected.aftermarketUnknown">Aftermarket parts, seller inspection only. Not publicly stress-tested.</template>
              <template v-else>Stress-tested: engine and matched transmission passed.</template>
            </p>

            <div v-if="selected.visibleParts?.length || selected.sellerClues?.length" class="block">
              <span class="caption">Seller can identify</span>
              <div class="sheet">
                <div class="lines">
                  <div v-for="part in selected.visibleParts" :key="part.label + part.value" class="line">
                    <span class="muted">{{ part.label }}</span><strong>{{ part.value }}</strong>
                  </div>
                  <div v-for="clue in selected.sellerClues" :key="clue" class="line">
                    <span class="muted">Seller note</span><strong>{{ clue }}</strong>
                  </div>
                </div>
              </div>
            </div>

            <div class="block">
              <span class="caption">Installation</span>
              <div class="sheet">
                <div class="lines">
                  <div class="line option-line">
                    <HouseSwitch row v-model="tradeIn">Trade in the outgoing engine</HouseSwitch>
                  </div>
                  <template v-if="quote?.success">
                    <div class="line"><span class="muted">Engine package</span><strong class="money"><MoneyAmount>{{ money(quote.packagePrice) }}</MoneyAmount></strong></div>
                    <div class="line"><span class="muted">Installation, incl. matched transmission</span><strong class="money"><MoneyAmount>{{ money(quote.installFee) }}</MoneyAmount></strong></div>
                    <div v-if="quote.tradeInCredit" class="line"><span class="muted">Outgoing engine trade-in</span><strong class="credit"><MoneyAmount>-{{ money(quote.tradeInCredit) }}</MoneyAmount></strong></div>
                  </template>
                </div>
              </div>
              <p v-if="!quote?.success && quote?.message" class="notice bad">{{ quote.message }}</p>
            </div>
          </div>

          <!-- total, right above the buttons that pay it -->
          <footer class="detail-foot" data-fk="foot" @focusin="rememberFocus">
            <div v-if="quote?.success" class="total-line">
              <span>Installed total</span>
              <strong class="money"><MoneyAmount>{{ money(quote.total) }}</MoneyAmount></strong>
            </div>
            <p v-if="quote?.success" class="hint">Ready in about {{ duration(quote.durationSeconds) }}. Pick it up at this shop's bay.</p>

            <div v-if="!confirmAction" class="actions">
              <HouseButton
                :disabled="busy"
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                v-bng-click="{ holdCallback: requestLoosePurchase, holdDelay: 1000, repeatInterval: 0 }">
                Buy loose package
              </HouseButton>
              <HouseButton
                variant="primary"
                binding="ok"
                :disabled="busy || !quote?.success"
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                v-bng-click="{ holdCallback: requestInstallPurchase, holdDelay: 1000, repeatInterval: 0 }">
                Purchase &amp; install
              </HouseButton>
            </div>
            <div v-else class="risk-confirm">
              <p class="notice bad">This engine exceeds its rated stress limit and may damage itself under load.</p>
              <div class="actions">
                <HouseButton variant="quiet" binding="back" :disabled="busy" @click="confirmAction = null">Cancel</HouseButton>
                <HouseButton
                  variant="danger"
                  binding="ok"
                  :disabled="busy"
                  v-bng-on-ui-nav:ok.asMouse.focusRequired
                  v-bng-click="{ holdCallback: confirmPurchase, holdDelay: 1000, repeatInterval: 0 }">
                  Accept risk
                </HouseButton>
              </div>
            </div>
          </footer>
        </aside>

        <aside v-else class="detail empty-detail">
          <p class="hint">Select an engine to see its details.</p>
        </aside>
      </div>
    </ComputerPanel>
  </ComputerWrapper>
</template>

<script setup>
import MoneyAmount from "../components/MoneyAmount.vue"
import { formatAccessEta } from "../utils/accessEta.js"
import { reportUiFailure } from "../utils/safeLua"

import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseSwitch } from "../components/house/index.js"
import { vBngBlur, vBngClick, vBngOnUiNav, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import { formatOdometer, moneyText } from "../utils/units"
import ComputerPanel from "../components/ComputerPanel.vue"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useScreenEntry, refocusIfLost } from "../composables/useScreenEntryFocus"

// controller entry focus bound to this screen (a late retry never touches the next screen)
const focusScreenEntry = useScreenEntry()

const { lua, units } = useBridge()
const data = ref({ listings: [], jobs: [], certifiablePackages: [] })
const selected = ref(null)
const quote = ref(null)
const tradeIn = ref(false)
const busy = ref(false)
const notice = ref(null)
const confirmAction = ref(null)
let timer
let noticeTimer
let quoteRequest = 0
let refreshInFlight = false
let statusInFlight = false
let refreshGeneration = 0
let statusRevision = null

// Share the same numeric formatting with text-only status and button labels.
const money = value => value == null ? "—" : moneyText(units, Number(value) || 0)
const power = hp => hp == null ? "—" : units.buildString("power", Number(hp), 0)
const torque = nm => nm == null ? "—" : units.buildString("torque", Number(nm), 0)
const distance = metres => formatOdometer(units, metres)
const condition = integrity => `${Math.round(Math.max(0, Math.min(1, Number(integrity) || 0)) * 100)}%`
const duration = formatAccessEta
const typeLabel = (kind, category) => {
  if (kind === "usedModified") return "Used, modified"
  if (category === "aftermarket") return kind === "new" ? "New aftermarket build" : "Lightly used aftermarket"
  return kind === "new" ? "New factory crate" : "Lightly used factory"
}
const listingGroups = computed(() => [
  {
    id: "factory",
    label: "Factory",
    description: "New and lightly used authored factory configurations.",
    listings: data.value.listings.filter(engine => engine.category === "factory"),
  },
  {
    id: "aftermarket",
    label: "Aftermarket",
    description: "New and lightly used custom, race, rally, police, and other authored configurations.",
    listings: data.value.listings.filter(engine => engine.category !== "factory"),
  },
].filter(group => group.listings.length))
// reliability word -> house status tone (Lua: Reliable / Fair / Risky / Questionable)
const reliabilityTone = value => {
  const v = String(value || "").toLowerCase()
  if (["reliable", "excellent", "good"].includes(v)) return "ok"
  if (v === "fair") return "warn"
  return "bad"
}
const certStatus = pkg => ({
  failed: "Stress limit exceeded",
  pending: "Stress test in progress",
}[pkg.certification?.status] || "Stored Engine Package")
const stressButtonLabel = pkg => ({ pending: "In progress", failed: "Failed" }[pkg.certification?.status]
  || `Hold to test, ${money(pkg.estimatedFee)}`)
const jobStatus = job => ({
  ready: "Ready for pickup",
  cancelling: "Restoring original configuration",
  retrieving: "Moving to pickup bay",
}[job.status] || `${duration(job.remainingSeconds)} remaining`)

async function refresh(preserve = true) {
  if (isUnmounted || refreshInFlight) return
  refreshInFlight = true
  refreshGeneration++
  try {
    const result = await lua.overhaul_career_parts_engines_engineRetail.requestData()
    if (isUnmounted) return
    if (!result?.success) { notice.value = result; return }
    const oldId = preserve ? selected.value?.id : null
    const listings = Array.isArray(result.listings) ? result.listings : []
    const next = {
      ...result,
      listings,
      jobs: Array.isArray(result.jobs) ? result.jobs : [],
      certifiablePackages: Array.isArray(result.certifiablePackages) ? result.certifiablePackages : [],
    }
    statusRevision = null
    if (JSON.stringify(data.value) === JSON.stringify(next)) return
    data.value = next
    selected.value = listings.find(item => item.id === oldId) || listings[0] || null
  } finally {
    refreshInFlight = false
  }
}

async function updateQuote() {
  if (!selected.value) { quote.value = null; return }
  const selectedId = selected.value.id
  const request = ++quoteRequest
  const result = await lua.overhaul_career_parts_engines_engineRetail.getQuote(selectedId, {
    mode: "install", tradeIn: tradeIn.value,
  })
  if (request === quoteRequest && selected.value?.id === selectedId) quote.value = result
}

function select(engine) { selected.value = engine; confirmAction.value = null }
watch([selected, tradeIn], updateQuote)

async function perform(action, clearSuccessAfter = 0) {
  busy.value = true
  try {
    notice.value = await action()
    window.clearTimeout(noticeTimer)
    if (clearSuccessAfter > 0 && notice.value?.success) {
      const shownNotice = notice.value
      noticeTimer = window.setTimeout(() => {
        if (notice.value === shownNotice) notice.value = null
      }, clearSuccessAfter)
    }
    await refresh()
  } catch (error) {
    window.clearTimeout(noticeTimer)
    notice.value = { success: false, message: error?.message || "The shop action could not be completed." }
  } finally { busy.value = false }
}

function buyLoose(acceptRisk = false) {
  if (selected.value) perform(() => lua.overhaul_career_parts_engines_engineRetail.purchaseLoose(selected.value.id, { acceptRisk }))
}
function install(acceptRisk = false) {
  if (selected.value) perform(() => lua.overhaul_career_parts_engines_engineRetail.startInstall(selected.value.id, {
    tradeIn: tradeIn.value, acceptRisk,
  }))
}
function requestPurchase(action) {
  if (!selected.value) return
  if (selected.value.exceedsStressLimit) { confirmAction.value = action; return }
  action === "loose" ? buyLoose() : install()
}
function requestLoosePurchase() { requestPurchase("loose") }
function requestInstallPurchase() { requestPurchase("install") }
function confirmPurchase() {
  const action = confirmAction.value
  confirmAction.value = null
  action === "loose" ? buyLoose(true) : install(true)
}
function certify(pkg) { perform(() => lua.overhaul_career_parts_engines_engineRetail.startCertification(pkg.id), 5000) }
function cancelJob(job) { perform(() => lua.overhaul_career_parts_engines_engineRetail.cancelJob(job.inventoryId)) }
function retrieveJob(job) { perform(() => lua.overhaul_career_parts_engines_engineRetail.retrieveVehicle(job.inventoryId)) }
function close() {
  // B unwinds the risk confirmation before it leaves the shop
  if (confirmAction.value) { confirmAction.value = null; return }
  lua.overhaul_career_career.closeAllMenus()
}

// Controller: refreshes rebuild the job / stress-test lines (the stress button is keyed by status) and
// the risk confirmation swaps the buy buttons, so focus drops to <body>. Put a pad back on the same line.
let lastFocusKey = null
function rememberFocus(event) {
  const key = event.target?.closest?.("[data-fk]")?.dataset.fk
  if (key) lastFocusKey = key
}
function pickFocus() {
  if (confirmAction.value) return document.querySelector(".risk-confirm button:not([disabled])")
  const host = lastFocusKey && [...document.querySelectorAll(".retail-panel [data-fk]")].find(el => el.dataset.fk === lastFocusKey)
  if (!host) return document.querySelector(".retail-panel .engine-row, .retail-panel .inventory button:not([disabled])")
  return host.matches("button") ? host : host.querySelector("button:not([disabled])") || host.querySelector("button")
}
// before any of these re-render, note which line has focus (focus events alone are not enough: a
// click-free A press or an unfocused window does not always deliver them)
watch([confirmAction, busy, () => data.value.jobs, () => data.value.certifiablePackages, () => data.value.listings],
  () => rememberFocus({ target: document.activeElement }), { flush: "pre" })
// the risk confirmation and a finished action move focus on purpose; list refreshes only repair it
watch(confirmAction, () => refocusIfLost(pickFocus, { force: true }), { flush: "post" })
watch(busy, isBusy => { if (!isBusy) refocusIfLost(pickFocus, { force: true }) }, { flush: "post" })
watch([() => data.value.jobs, () => data.value.certifiablePackages, () => data.value.listings], () => refocusIfLost(pickFocus), { flush: "post" })

async function refreshStatus() {
  if (isUnmounted || busy.value || refreshInFlight || statusInFlight) return
  statusInFlight = true
  const generation = refreshGeneration
  try {
    const result = await lua.overhaul_career_parts_engines_engineRetail.requestStatus()
    if (isUnmounted || busy.value || generation !== refreshGeneration || !result?.success) return
    const jobs = Array.isArray(result.jobs) ? result.jobs : []
    const stressTests = Array.isArray(result.stressTests) ? result.stressTests : []
    const revision = JSON.stringify({ jobs, stressTests })
    if (revision === statusRevision) return
    statusRevision = revision
    if (JSON.stringify(data.value.jobs) !== JSON.stringify(jobs)) data.value.jobs = jobs
    const statuses = new Map(stressTests.map(item => [item.id, item.certification]))
    const packages = data.value.certifiablePackages
      .map(pkg => ({ ...pkg, certification: statuses.get(pkg.id) || pkg.certification,
        canStart: !statuses.get(pkg.id) || !["pending", "failed"].includes(statuses.get(pkg.id)?.status) }))
      .filter(pkg => statuses.get(pkg.id)?.status !== "passed")
    if (JSON.stringify(data.value.certifiablePackages) !== JSON.stringify(packages)) data.value.certifiablePackages = packages
  } catch (_) {
    if (!isUnmounted) reportUiFailure(_, "refresh status (EngineRetail)")
  } finally {
    statusInFlight = false
  }
}

const entryFocused = ref(false) // autofocus mark is for entry only
let isUnmounted = false
onMounted(async () => {
  await refresh(false)
  if (isUnmounted) return
  // mod route: wake the screen scope so the d-pad starts on the first engine
  focusScreenEntry().then(() => setTimeout(() => { entryFocused.value = true }, 600))
  timer = window.setInterval(refreshStatus, 5000)
})
onBeforeUnmount(() => {
  isUnmounted = true
  window.clearInterval(timer)
  window.clearTimeout(noticeTimer)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* House engine shop. em off a resolution-scaled font so the panel keeps its share of the screen.
   Two classes so these win over ComputerPanel's own root rules. */
.retail-panel.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(96vw, 78em);
  height: min(91vh, 50em);
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  padding: var(--space-3);
  border-radius: var(--radius-control);
  border-bottom: 0; // ComputerPanel's orange bottom edge
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  :deep(.panel-content) {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-height: 0;
    height: 100%;
  }
}

.notices {
  display: grid;
  gap: var(--space-1);
}

.workspace {
  flex: 1 1 auto;
  display: grid;
  grid-template-columns: minmax(0, 1.05fr) minmax(0, 0.95fr);
  gap: var(--space-3);
  min-height: 0;
}

/* ---- left: listings, jobs, stress tests */
.inventory {
  display: flex;
  flex-direction: column;
  gap: 1em;
  min-height: 0;
  padding: 0.2em 0.5em 0.6em 0.2em;
}
.list-head {
  display: grid;
  gap: 0.15em;
  h2 {
    font-size: 1.25em;
  }
}
.listing-group {
  display: grid;
  gap: 0.45em;
}
.engine-list {
  display: grid;
  gap: 0.4em;
}
.engine-row {
  position: relative;
  appearance: none;
  display: grid;
  gap: 0.35em;
  width: 100%;
  margin: 0;
  padding: 0.65em 0.8em 0.55em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover {
    background: var(--panel-2);
  }
  // full-width rows in a scroll box: inset ring for the pad class and keyboard alike
  @include house-focus(var(--focus-inset));
  &.selected {
    background: var(--panel-2);
    .engine-name {
      color: var(--accent-soft);
    }
  }
}
.engine-top {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1em;
}
.engine-name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 1.05em;
  font-weight: 800;
}
.engine-price {
  flex: 0 0 auto;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.engine-specs {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.25em 1.1em;
}
.spec {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  white-space: nowrap;
  .spec-icon {
    font-size: 1.2em;
    color: var(--faint);
  }
  &.ok { color: var(--ok-ink); }
  &.warn { color: var(--warn); }
  &.bad { color: var(--bad); }
}
.empty-line {
  padding: 0.6em 0.2em;
}

.job-line,
.cert-line {
  align-items: center;
  .row-copy span.is-ready {
    color: var(--ok-ink);
  }
  .row-copy span.bad {
    color: var(--bad);
  }
}
.line-actions {
  flex: 0 0 auto;
  display: flex;
  gap: var(--space-1);
}

/* ---- right: detail, then the total and buy buttons pinned to the bottom */
.detail {
  display: flex;
  flex-direction: column;
  min-height: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.detail-scroll {
  flex: 1 1 auto;
  min-height: 0;
  display: flex;
  flex-direction: column;
  gap: 1em;
  padding: 0.9em 0.6em 0.9em 1em;
}
.detail-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 1em;
  h1 {
    margin: 0.1em 0 0;
    font-size: 1.55em;
    font-weight: 800;
    line-height: 1.15;
  }
}
.detail-copy {
  display: grid;
  gap: 0.1em;
  min-width: 0;
}
.detail-price {
  flex: 0 0 auto;
  padding-top: 0.6em;
  color: var(--money);
  font-size: 1.35em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
}
.facts {
  row-gap: 0.9em;
}
/* a fact with an explanation: reachable by the d-pad, the tip shows on focus */
.has-tip {
  position: relative;
  border-radius: var(--radius-control);
  cursor: help;
  @include house-focus;
}
.block {
  display: grid;
  gap: 0.45em;
}
.sheet .line {
  strong {
    font-weight: 700;
  }
  .money {
    color: var(--money);
    font-variant-numeric: tabular-nums;
  }
  .credit {
    color: var(--ok-ink);
    font-variant-numeric: tabular-nums;
  }
}
.option-line {
  padding-top: 0.5em;
  padding-bottom: 0.4em;
  :deep(.house-switch) {
    font-weight: 700;
  }
}

.detail-foot {
  flex: 0 0 auto;
  display: grid;
  gap: 0.35em;
  padding: 0.8em 1em 1em;
}
.total-line {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1em;
  font-size: 1.3em;
  font-weight: 900;
  .money {
    color: var(--money);
    font-variant-numeric: tabular-nums;
  }
}
.actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-2);
  margin-top: 0.4em;
  > * {
    width: 100%;
  }
}
.risk-confirm {
  display: grid;
  gap: var(--space-2);
}

.empty-detail {
  display: grid;
  place-items: center;
  padding: 1em;
}

@media (max-width: 75rem) {
  .workspace {
    grid-template-columns: 1fr;
  }
}
</style>
