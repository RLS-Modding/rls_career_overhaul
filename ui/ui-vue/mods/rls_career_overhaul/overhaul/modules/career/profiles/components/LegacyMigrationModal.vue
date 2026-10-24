<!-- Legacy save migration report and options, shown when a legacy or RLS save is loaded.
     Map, in reading order (this is the shell; the parts are in legacyMigration/):
     1. Props, emits, the result watch, and the values the Result step needs (the Result step is drawn by this template).
     2. Form state. This file owns every mutable value: targetProfile, vehiclePolicy, selectedCashOutIds,
        selectedGarageIds, acknowledged, step, expanded, detailsOpen and assetsOpen. The report watch re-seeds them all.
     3. Derived values: blocked, canMigrate, blockReason, issue buckets, asset totals and the policy option list.
     4. The functions that change the state above: findings toggle and asset selection.
     5. Navigation, focus and lifecycle. These stay as plain named functions, because
        tests/save/migration_modal_navigation_test.mjs reads them from this file.
     6. submit(), the one payload sent to the bridge.
     Parts: LegacyMigrationReport (Review step) and LegacyMigrationAssets (asset list). They get explicit
     values and emit semantic events back here; none writes a prop. The policy choice cards
     and the note grouping stay in this file. Pure helpers: findings.js, format.js. Shared colour tokens and skin: the src overlay legacyMigration/_tokens.scss and _skin.scss.
     CEF typing for the name field comes from useCefTyping; unmounting while the field is focused releases it. -->
<template>
  <teleport to="body">
    <!-- The teleported modal needs its own navigation scope. -->
    <dialog open ref="dialogElement" tabindex="-1"
      v-bng-scoped-nav="{ scopeId: 'career-migration-modal', activateOnMount: true, trapPolicy: 'always', autoFocusDelay: 0, canDeactivate: () => (onNavBack(), false) }"
      class="lmm-backdrop" data-focus-host
      @cancel.prevent="onNavBack">
      <!-- No click-outside close: a stray click must not throw away the migration choices. -->
      <section class="lmm" :class="{ 'lmm--result': result }" role="dialog" aria-modal="true" aria-labelledby="legacy-migration-title">
        <header class="lmm-header">
          <div class="lmm-title">
            <div class="lmm-kicker">{{ report.importSource ? "RLS career save" : "Legacy career save" }}</div>
            <h2 id="legacy-migration-title">{{ result ? "Migration complete" : "Compatibility report" }}</h2>
            <p class="lmm-meta">
              <span>{{ report.displayName || report.profile || "Save" }}</span>
              <span>{{ report.migrationLabel || `v${report.sourceVersion ?? "?"} → v${report.targetVersion}` }}</span>
              <template v-if="report.level">
                <span>{{ report.level }}</span>
              </template>
            </p>
          </div>

          <div class="lmm-header-right">
            <div :class="['lmm-verdict', result ? 'lmm-verdict--ok' : blocked ? 'lmm-verdict--blocked' : needsReview ? 'lmm-verdict--review' : 'lmm-verdict--ok']">
              <span class="lmm-verdict-dot" />
              {{ result ? "Complete" : blocked ? "Cannot migrate" : needsReview ? "Needs review" : "Ready" }}
            </div>
            <button class="lmm-close" type="button" :disabled="busy" aria-label="Close" @click="emit('cancel')">×</button>
          </div>
        </header>

        <!-- Two steps rather than one long scroll: understand the save, then decide
             what to do with it. Both stay clickable so nothing is trapped behind a wizard. -->
        <nav v-if="!result" class="lmm-steps" aria-label="Migration steps">
          <button
            type="button"
            :class="['lmm-step', { 'is-active': step === 'report' }]"
            :aria-current="step === 'report' ? 'step' : undefined"
            @click="step = 'report'">
            <span class="lmm-step-num">1</span>
            <span class="lmm-step-label">Review</span>
            <span v-if="issueTotal" class="lmm-step-badge">{{ issueTotal }}</span>
          </button>
          <span class="lmm-step-line" />
          <button
            type="button"
            :class="['lmm-step', { 'is-active': step === 'options', 'is-disabled': blocked }]"
            :aria-current="step === 'options' ? 'step' : undefined"
            :disabled="blocked"
            @click="step = 'options'">
            <span class="lmm-step-num">2</span>
            <span class="lmm-step-label">Choose what to keep</span>
          </button>
        </nav>

        <div class="lmm-body">
          <!-- Review and the asset list are presentation children. They receive values from this shell and report
               changes back as events, so the state and its rules stay in one place. -->
          <!-- ── Result ───────────────────────────────────────────────────── -->
          <template v-if="result">
            <div class="lmm-done" aria-live="polite">
              <span class="lmm-done-icon">✓</span>
              <div>
                <div class="lmm-done-label">Migrated copy created</div>
                <div class="lmm-done-name">{{ result.targetProfile }}</div>
                <div class="lmm-done-sub">Your original save “{{ originalName }}” is unchanged.</div>
              </div>
            </div>

            <div class="lmm-summary">
              <div class="lmm-stats" :class="{ 'lmm-stats--4': hasCashOut }">
                <div class="lmm-stat">
                  <strong>{{ result.summary?.vehiclesMigrated || 0 }}</strong>
                  <span>Vehicles migrated</span>
                </div>
                <div class="lmm-stat">
                  <strong>{{ result.summary?.partsMigrated || 0 }}</strong>
                  <span>Parts updated</span>
                </div>
                <div class="lmm-stat">
                  <strong>{{ result.summary?.itemsMovedToInventory || 0 }}</strong>
                  <span>Moved to loose inventory</span>
                </div>
                <div v-if="hasCashOut" class="lmm-stat">
                  <strong><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(result.cashOut.amountCredited, 2) }}</strong>
                  <span>Credited for {{ result.cashOut.vehiclesSold || 0 }} vehicles, {{ result.cashOut.garagesSold || 0 }} garages, {{ result.cashOut.loosePartsSold || 0 }} parts</span>
                </div>
              </div>
            </div>

            <section v-if="resultWarnings.length" class="lmm-section">
              <div class="lmm-section-heading">
                <h3>Notes</h3>
                <span class="lmm-count">{{ resultWarnings.length }}</span>
              </div>
              <div class="lmm-notes">
                <div v-for="group in resultNoteGroups" :key="group.name" class="lmm-note-group">
                  <div class="lmm-note-group-title">{{ group.name }}</div>
                  <div v-for="(note, index) in group.notes" :key="index" class="lmm-note-row">
                    <div class="lmm-note-head">
                      <code v-if="note.part" class="lmm-code">{{ note.part }}</code>
                      <span class="lmm-note-text">{{ note.text }}</span>
                    </div>
                    <div v-if="note.segments.length > 1" class="lmm-path" :title="note.path">
                      <template v-for="(segment, i) in note.segments" :key="i">
                        <span v-if="i" class="lmm-path-sep">›</span><span>{{ segment }}</span>
                      </template>
                    </div>
                  </div>
                </div>
              </div>
              <p class="lmm-footnote">These notes are also kept in the migrated save's migration report.</p>
            </section>
          </template>

          <!-- ── Step 1 ───────────────────────────────────────────────────── -->
          <LegacyMigrationReport
            v-else-if="step === 'report'"
            :vehicle-total="report.vehicleCount || 0"
            :vehicles-at-risk="report.incompatibleVehicleCount"
            :garage-total="report.garageCount || 0"
            :garages-at-risk="report.unavailableGarageCount"
            :total-asset-value="totalAssetValue"
            :blocked="blocked"
            :issue-total="issueTotal"
            :issue-buckets="issueBuckets"
            :expanded-keys="expanded"
            :details-open="detailsOpen"
            @toggle-details="detailsOpen = !detailsOpen"
            @toggle-group="toggleGroup" />

          <!-- ── Step 2 ───────────────────────────────────────────────────── -->
          <template v-else>
            <!-- A current RLS save copied into Overhaul was never migrated on RLS, so it
                 keeps everything (policyChoice false); 0.39 saves keep RLS's choices. -->
            <section v-if="policyChoice" class="lmm-section">
              <div class="lmm-section-heading">
                <h3>What should happen to legacy assets?</h3>
              </div>
              <div class="lmm-policy">
                <label
                  v-for="option in policyOptions"
                  :key="option.value"
                  :class="['lmm-policy-card', { 'is-selected': vehiclePolicy === option.value }]">
                  <input v-model="vehiclePolicy" type="radio" :value="option.value" class="lmm-policy-input" />
                  <span class="lmm-policy-mark" aria-hidden="true" />
                  <span class="lmm-policy-body">
                    <span class="lmm-policy-title">
                      {{ option.title }}
                      <em v-if="option.recommended" class="lmm-recommended">Recommended</em>
                    </span>
                    <small>{{ option.blurb }}</small>
                    <span class="lmm-policy-outcome">{{ option.outcome }}<template v-if="option.money != null"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoney(option.money) }}{{ option.outcomeAfter }}</template></span>
                  </span>
                </label>
              </div>
            </section>

            <LegacyMigrationAssets
              v-if="hasAssets"
              :pickable="individualPolicy"
              :assets-open="assetsOpen"
              :assets-visible="assetsVisible"
              :asset-count="assetCount"
              :vehicles="vehicles"
              :garages="garages"
              :vehicle-counts="vehicleCounts"
              :garage-counts="garageCounts"
              :selected-cash-out-ids="selectedCashOutIds"
              :selected-garage-ids="selectedGarageIds"
              :individual-total="individualTotal"
              @toggle-assets="assetsOpen = !assetsOpen"
              @select-all="selectAll"
              @select-issues="selectIssuesOnly"
              @select-none="selectNone"
              @toggle-vehicle="toggleVehicle"
              @toggle-garage="toggleGarage" />

            <section class="lmm-section">
              <label class="lmm-name-label" for="migration-profile-name">Name the migrated copy</label>
              <input
                id="migration-profile-name"
                v-model="targetProfile"
                class="lmm-name"
                maxlength="100"
                :disabled="busy || report.preparedMigration"
                @focus="onInputFocus"
                @blur="onInputBlur" />
              <p class="lmm-hint">The original profile keeps its name and its data.</p>
            </section>
          </template>

          <p v-if="error" class="lmm-error">{{ error }}</p>
        </div>

        <footer class="lmm-footer">
          <label v-if="!result && step === 'options'" class="lmm-ack">
            <input v-model="acknowledged" type="checkbox" :disabled="busy" />
            <span>
              I understand the selected vehicles, parts, and garages are removed only from the migrated copy, that mod
              compatibility cannot be guaranteed, and that my original save stays untouched.
            </span>
          </label>
          <p v-else-if="!result" class="lmm-footer-hint">
            {{ blocked ? "Migration is unavailable until the blockers above are resolved." : "Review the findings, then choose what to keep." }}
          </p>

          <div class="lmm-actions">
            <span v-if="blockReason" class="lmm-block-reason">{{ blockReason }}</span>
            <button class="lmm-btn lmm-btn--secondary" type="button" :disabled="busy" @click="onSecondary">
              {{ result ? "Close" : step === "options" ? "Back" : "Cancel" }}
            </button>
            <button
              v-if="!result && step === 'report'"
              class="lmm-btn lmm-btn--primary"
              type="button"
              :disabled="blocked || busy"
              @click="step = 'options'">
              Continue
            </button>
            <button v-else-if="result" ref="loadCopyButton" class="lmm-btn lmm-btn--primary" type="button" :disabled="busy" @click="emit('load')">Load migrated copy</button>
            <button v-else class="lmm-btn lmm-btn--primary" type="button" :disabled="!canMigrate" @click="submit">
              {{ busy ? "Creating copy…" : report.preparedMigration ? "Review prepared copy" : "Create migrated copy" }}
            </button>
          </div>
        </footer>
      </section>
    </dialog>
  </teleport>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { vBngScopedNav } from "@/common/directives"
import { BngIcon, icons } from "@/common/components/base"
import { DOM_UI_NAVIGATION_EVENT } from "@/services/uiNav/constants"
import { useCefTyping } from "../../composables/useCefTyping.js"
import LegacyMigrationAssets from "./legacyMigration/LegacyMigrationAssets.vue"
import LegacyMigrationReport from "./legacyMigration/LegacyMigrationReport.vue"
import { buildIssueBuckets } from "./legacyMigration/findings.js"
import { formatMoney } from "./legacyMigration/format.js"

const props = defineProps({
  report: { type: Object, required: true },
  busy: Boolean,
  error: { type: String, default: "" },
  result: { type: Object, default: null },
})

const emit = defineEmits(["cancel", "migrate", "load"])
const dialogElement = ref(null)
const loadCopyButton = ref(null)
watch(() => props.result && !props.busy, async ready => {
  if (!ready) return
  await nextTick()
  loadCopyButton.value?.focus()
})
// Migration warnings as grouped notes for the Result step (pure helpers, no Vue and no bridge calls).
function titleCase(name) {
  return name.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase())
}

// Warnings arrive as text with an embedded part path, e.g. "Kept /covet_body/.../skin_x in loose part inventory: reason".
function parseNote(text) {
  const match = String(text).match(/(\/[\w.\-]+(?:\/[\w.\-]+)+)/)
  if (!match) return { group: "General", part: "", path: "", segments: [], text: String(text) }
  const path = match[1]
  const segments = path.split("/").filter(Boolean)
  const rest = String(text).replace(path, "").replace(/\s+/g, " ").trim()
  const sentence = rest.replace(/^(\w+)\s+in\s+/i, "$1 in ").replace(/:\s*/, " — ")
  return {
    group: titleCase(segments[0].replace(/_body$/, "")),
    part: segments[segments.length - 1],
    path,
    segments,
    text: sentence.charAt(0).toUpperCase() + sentence.slice(1),
  }
}

/** Groups notes by their heading, in first-seen order. */
function buildNoteGroups(warnings) {
  const groups = new Map()
  for (const warning of warnings) {
    const note = parseNote(warning)
    if (!groups.has(note.group)) groups.set(note.group, { name: note.group, notes: [] })
    groups.get(note.group).notes.push(note)
  }
  return [...groups.values()]
}

const resultWarnings = computed(() => [
  ...asArray(props.result?.summary?.warnings),
  ...asArray(props.result?.report?.issues)
    .filter(issue => issue.code !== "save.versionUpgrade")
    .map(issue => `${issue.title}: ${issue.detail}`),
])
const resultNoteGroups = computed(() => buildNoteGroups(resultWarnings.value))

const hasCashOut = computed(() => {
  const c = props.result?.cashOut
  return !!(c && (c.vehiclesSold || c.garagesSold || c.loosePartsSold))
})

const targetProfile = ref("")
const vehiclePolicy = ref("sellall")
const selectedCashOutIds = ref([])
const selectedGarageIds = ref([])
const acknowledged = ref(false)

const step = ref("report")
const expanded = ref(new Set())
const detailsOpen = ref(false)
const assetsOpen = ref(false)

/** Lua serialises an empty table as `{}`, not `[]`, so never assume an array came back. */
function asArray(value) {
  return Array.isArray(value) ? value : []
}

const originalName = computed(() => props.report.displayName || props.report.profile)
const blocked = computed(() => props.report.canMigrate === false || Number(props.report.blockerCount || 0) > 0)
const policyChoice = computed(() => props.report.policyChoice !== false)
const issues = computed(() => asArray(props.report.issues))
const issueTotal = computed(() => issues.value.length)
const needsReview = computed(() => issueTotal.value > 0)
const issueBuckets = computed(() => buildIssueBuckets(issues.value))

const canMigrate = computed(() =>
  !props.busy && !blocked.value && acknowledged.value && !!targetProfile.value.trim()
)

/** Says why the primary button is dead instead of leaving a greyed-out mystery. */
const blockReason = computed(() => {
  // The report step already states the blocker case in its banner and footer hint.
  if (props.busy || step.value !== "options") return ""
  if (!targetProfile.value.trim()) return "Name the migrated copy"
  if (!acknowledged.value) return "Tick the acknowledgement to continue"
  return ""
})

watch(
  () => props.report,
  report => {
    targetProfile.value = report?.defaultTargetProfile || report?.profile || ""
    vehiclePolicy.value = report?.policyChoice === false || report?.sourceVersion === 64 ? "preserve" : "sellall"
    selectedCashOutIds.value = asArray(report?.vehicles)
      .filter(vehicle => !vehicle.available)
      .map(vehicle => Number(vehicle.id))
      .filter(Number.isFinite)
    selectedGarageIds.value = asArray(report?.garages)
      .filter(garage => !garage.available)
      .map(garage => String(garage.id))
    acknowledged.value = false
    step.value = "report"
    expanded.value = new Set()
    detailsOpen.value = false
    assetsOpen.value = false
  },
  { immediate: true }
)

function toggleGroup(key) {
  const next = new Set(expanded.value)
  if (next.has(key)) next.delete(key)
  else next.add(key)
  expanded.value = next
}

/* ── Assets & policy ───────────────────────────────────────────────────── */

const vehicles = computed(() => asArray(props.report.vehicles))
const garages = computed(() => asArray(props.report.garages))
const hasAssets = computed(() => vehicles.value.length > 0 || garages.value.length > 0)
const assetCount = computed(() => vehicles.value.length + garages.value.length)
const individualPolicy = computed(() => vehiclePolicy.value === "individual")
const assetsVisible = computed(() => individualPolicy.value || assetsOpen.value)
const vehicleCounts = computed(() => ({
  available: props.report.compatibleVehicleCount || 0,
  atRisk: props.report.incompatibleVehicleCount || 0,
}))
const garageCounts = computed(() => ({
  available: props.report.availableGarageCount || 0,
  atRisk: props.report.unavailableGarageCount || 0,
}))

const totalAssetValue = computed(
  () =>
    vehicles.value.reduce((sum, v) => sum + (Number(v.savedValue) || 0), 0)
    + garages.value.reduce((sum, g) => sum + (Number(g.savedValue) || 0), 0)
)

const individualTotal = computed(
  () =>
    vehicles.value
      .filter(v => selectedCashOutIds.value.includes(Number(v.id)))
      .reduce((sum, v) => sum + (Number(v.savedValue) || 0), 0)
    + garages.value
      .filter(g => selectedGarageIds.value.includes(String(g.id)))
      .reduce((sum, g) => sum + (Number(g.savedValue) || 0), 0)
)

const atRiskCount = computed(
  () => vehicles.value.filter(v => !v.available).length + garages.value.filter(g => !g.available).length
)

const policyOptions = computed(() => [
  {
    value: "sellall",
    title: "Sell everything",
    recommended: props.report.sourceVersion !== 64,
    blurb: "Removes every legacy vehicle, part, and garage record and credits their estimated value.",
    // Amount split out so the card can put the currency glyph before it.
    outcome: "Credits about ",
    money: totalAssetValue.value,
    outcomeAfter: ", nothing can break later",
  },
  {
    value: "individual",
    title: "Choose what to sell",
    blurb: "Pick the assets to convert to cash. At-risk items start selected.",
    outcome: `${selectedCashOutIds.value.length + selectedGarageIds.value.length} of ${assetCount.value} selected, `,
    money: individualTotal.value,
  },
  {
    value: "preserve",
    title: "Keep everything",
    recommended: props.report.sourceVersion === 64,
    blurb: "Keeps all vehicle and garage records. Missing content stays quarantined and cannot spawn.",
    outcome: atRiskCount.value
      ? `Keeps ${assetCount.value} items, ${atRiskCount.value} stay quarantined`
      : `Keeps all ${assetCount.value} items`,
  },
])

function selectAll() {
  selectedCashOutIds.value = vehicles.value.map(v => Number(v.id)).filter(Number.isFinite)
  selectedGarageIds.value = garages.value.map(g => String(g.id))
}

function selectNone() {
  selectedCashOutIds.value = []
  selectedGarageIds.value = []
}

function selectIssuesOnly() {
  selectedCashOutIds.value = vehicles.value.filter(v => !v.available).map(v => Number(v.id)).filter(Number.isFinite)
  selectedGarageIds.value = garages.value.filter(g => !g.available).map(g => String(g.id))
}

function toggleVehicle(id) {
  id = Number(id)
  if (selectedCashOutIds.value.includes(id)) {
    selectedCashOutIds.value = selectedCashOutIds.value.filter(value => value !== id)
  } else {
    selectedCashOutIds.value = [...selectedCashOutIds.value, id]
  }
}

function toggleGarage(id) {
  id = String(id)
  if (selectedGarageIds.value.includes(id)) {
    selectedGarageIds.value = selectedGarageIds.value.filter(value => value !== id)
  } else {
    selectedGarageIds.value = [...selectedGarageIds.value, id]
  }
}

const { onFocus: onInputFocus, onBlur: onInputBlur } = useCefTyping()

function onSecondary() {
  if (!props.result && step.value === "options") step.value = "report"
  else emit("cancel")
}

function onNavBack() {
  if (props.busy) return
  onSecondary()
}

function onModalNavigation(event) {
  if (!['back', 'menu'].includes(event.detail?.name)) return
  event.preventDefault()
  event.stopImmediatePropagation()
  if (event.detail.value) onNavBack()
}

async function focusDialog() {
  await nextTick()
  const dialog = dialogElement.value
  if (!dialog || dialog.contains(document.activeElement)) return
  const target = dialog.querySelector('button:not(:disabled)') || dialog
  target.focus()
}

watch(() => [step.value, props.busy], focusDialog)
onMounted(() => {
  document.addEventListener(DOM_UI_NAVIGATION_EVENT, onModalNavigation, true)
  focusDialog()
})
onBeforeUnmount(() => {
  document.removeEventListener(DOM_UI_NAVIGATION_EVENT, onModalNavigation, true)
})

function submit() {
  if (!canMigrate.value) return
  let cashOutVehicleIds = []
  let cashOutGarageIds = []
  if (vehiclePolicy.value === "sellall") {
    cashOutVehicleIds = vehicles.value.map(vehicle => Number(vehicle.id)).filter(Number.isFinite)
    cashOutGarageIds = garages.value.map(garage => String(garage.id))
  } else if (vehiclePolicy.value === "individual") {
    cashOutVehicleIds = [...selectedCashOutIds.value]
    cashOutGarageIds = [...selectedGarageIds.value]
  }

  emit("migrate", {
    targetProfile: targetProfile.value.trim(),
    vehiclePolicy: vehiclePolicy.value,
    cashOutVehicleIds,
    cashOutGarageIds,
    sellParts: vehiclePolicy.value === "sellall",
  })
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/tokens" as *;
@use "@/styles/rls_career_overhaul/modules/career/profiles/components/legacyMigration/skin" as *;

@include lmm-section;
@include lmm-section-heading;
@include lmm-count;
@include lmm-summary-panel;
@include lmm-hint;
@include lmm-currency;

.lmm-backdrop {
  margin: 0;
  border: 0;
  width: 100%;
  height: 100%;
  max-width: none;
  max-height: none;
  box-sizing: border-box;
  color: inherit;
  position: fixed;
  inset: 0;
  z-index: 10000;
  display: grid;
  place-items: center;
  padding: calc-ui-rem(1.5);
  background: rgba(2, 5, 12, 0.86);
  backdrop-filter: blur(10px);
}

.lmm {
  width: min(calc-ui-rem(58), 94vw);
  max-height: 88vh;
  display: grid;
  grid-template-rows: auto auto minmax(0, 1fr) auto;
  overflow: hidden;
  color: #fff;
  background: linear-gradient(160deg, #101623, #070a12 62%);
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: calc-ui-rem(0.9);
  box-shadow: 0 1.8rem 4.5rem rgba(0, 0, 0, 0.7);
  font-size: calc-ui-rem();
}

.lmm--result {
  grid-template-rows: auto minmax(0, 1fr) auto;
}

/* ── Header ─────────────────────────────────────────────────────────── */

.lmm-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1em;
  padding: 1em 1.15em 0.9em;
  border-bottom: 1px solid rgba(71, 85, 105, 0.3);

  h2 {
    margin: 0.12em 0 0.2em;
    font-size: 1.45em;
    line-height: 1.1;
  }
}

.lmm-kicker {
  color: $accent;
  font-size: 0.68em;
  font-weight: 900;
  letter-spacing: 0.1em;
  text-transform: uppercase;
}

.lmm-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4em 0.8em;
  margin: 0;
  color: $muted;
  font-size: 0.8em;
}

.lmm-header-right {
  display: flex;
  align-items: center;
  gap: 0.6em;
}

.lmm-verdict {
  display: inline-flex;
  align-items: center;
  gap: 0.45em;
  padding: 0.3em 0.7em;
  border-radius: 999px;
  border: 1px solid currentColor;
  font-size: 0.72em;
  font-weight: 800;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  white-space: nowrap;
}
.lmm-verdict-dot {
  width: 0.55em;
  height: 0.55em;
  border-radius: 50%;
  background: currentColor;
}
.lmm-verdict--blocked { color: $danger; background: rgba(240, 71, 71, 0.12); }
.lmm-verdict--review { color: $risk; background: rgba(251, 146, 60, 0.12); }
.lmm-verdict--ok { color: $ok; background: rgba(74, 222, 128, 0.12); }

.lmm-close {
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.55);
  font-size: 1.8em;
  line-height: 1;
  cursor: pointer;

  &:hover { color: #fff; }
}

/* ── Steps ──────────────────────────────────────────────────────────── */

.lmm-steps {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.65em 1.15em;
  background: rgba(2, 5, 12, 0.45);
  border-bottom: 1px solid rgba(71, 85, 105, 0.3);
}

.lmm-step {
  display: inline-flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.32em 0.75em 0.32em 0.35em;
  border: 1px solid transparent;
  border-radius: 999px;
  background: transparent;
  color: $muted;
  font-family: inherit;
  font-size: 0.82em;
  cursor: pointer;

  &:hover:not(.is-disabled) { color: #fff; }

  &.is-active {
    color: #fff;
    border-color: rgba(255, 122, 26, 0.55);
    background: rgba(255, 122, 26, 0.12);

    .lmm-step-num { background: $accent; color: #10131a; }
  }

  &.is-disabled,
  &:disabled { opacity: 0.4; cursor: default; }
}

.lmm-step-num {
  display: grid;
  place-items: center;
  width: 1.7em;
  height: 1.7em;
  border-radius: 50%;
  background: rgba(148, 163, 184, 0.2);
  font-size: 0.85em;
  font-weight: 800;
}

.lmm-step-label { font-weight: 700; }

.lmm-step-badge {
  padding: 0.05em 0.45em;
  border-radius: 999px;
  background: rgba(251, 146, 60, 0.2);
  color: $risk;
  font-size: 0.8em;
  font-weight: 800;
}

.lmm-step-line {
  flex: 0 0 1.5em;
  height: 1px;
  background: rgba(148, 163, 184, 0.3);
}

/* ── Body ───────────────────────────────────────────────────────────── */

.lmm-body {
  overflow: auto;
  padding: 1em 1.15em 1.2em;
}

.lmm-name-label {
  display: block;
  margin-bottom: 0.35em;
  font-size: 0.9em;
  font-weight: 800;
}

.lmm-name {
  width: 100%;
  box-sizing: border-box;
  padding: 0.55em 0.7em;
  border: 1px solid $line;
  border-radius: 8px;
  outline: none;
  color: #fff;
  background: rgba(2, 5, 12, 0.75);
  font-family: inherit;
  font-size: 0.95em;

  &:focus { border-color: $accent; }
  &:disabled { opacity: 0.6; }
}

.lmm-error {
  margin: 0.8em 0 0;
  padding: 0.6em 0.75em;
  border-radius: 8px;
  border-left: 3px solid $danger;
  background: rgba(240, 71, 71, 0.12);
  color: #fecaca;
  font-size: 0.85em;
}

/* ── Footer ─────────────────────────────────────────────────────────── */

.lmm-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1.2em;
  padding: 0.85em 1.15em;
  border-top: 1px solid rgba(71, 85, 105, 0.3);
  background: rgba(2, 5, 12, 0.55);
}

.lmm-ack {
  display: flex;
  align-items: flex-start;
  gap: 0.55em;
  min-width: 0;
  color: rgba(255, 255, 255, 0.6);
  font-size: 0.74em;
  line-height: 1.35;
  cursor: pointer;

  input { margin-top: 0.15em; accent-color: $accent; }
  &:hover { color: rgba(255, 255, 255, 0.85); }
}

.lmm-footer-hint {
  margin: 0;
  min-width: 0;
  color: $muted;
  font-size: 0.78em;
}

.lmm-actions {
  display: flex;
  align-items: center;
  gap: 0.55em;
  flex: 0 0 auto;
}

.lmm-block-reason {
  color: $risk;
  font-size: 0.72em;
  text-align: right;
}

.lmm-btn {
  padding: 0.55em 1em;
  border: 1px solid transparent;
  border-radius: 8px;
  color: #fff;
  font-family: inherit;
  font-size: 0.88em;
  font-weight: 800;
  white-space: nowrap;
  cursor: pointer;

  &:disabled { opacity: 0.4; cursor: default; }
}
.lmm-btn--secondary {
  background: rgba(51, 65, 85, 0.6);
  border-color: rgba(100, 116, 139, 0.5);

  &:not(:disabled):hover { background: rgba(71, 85, 105, 0.8); }
}
.lmm-btn--primary {
  background: $accent;
  border-color: #ff9a4d;
  color: #10131a;

  &:not(:disabled):hover { background: #ff8c33; }
}

@media (max-width: 900px) {
  .lmm-footer { flex-direction: column; align-items: stretch; }
  .lmm-actions { justify-content: flex-end; }
}

.lmm-policy {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.5em;
}

.lmm-policy-card {
  position: relative;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  gap: 0.55em;
  padding: 0.75em;
  border: 1px solid $line;
  border-radius: 10px;
  background: $surface;
  cursor: pointer;
  transition: border-color 0.12s ease, background 0.12s ease;

  &:hover { border-color: rgba(255, 122, 26, 0.45); }

  &.is-selected {
    border-color: rgba(255, 122, 26, 0.9);
    background: rgba(255, 122, 26, 0.1);

    .lmm-policy-mark {
      border-color: $accent;
      background: radial-gradient(circle, $accent 0 42%, transparent 46%);
    }
  }
}

.lmm-policy-input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

.lmm-policy-mark {
  width: 1em;
  height: 1em;
  margin-top: 0.15em;
  border: 1px solid rgba(148, 163, 184, 0.7);
  border-radius: 50%;
}

.lmm-policy-body {
  display: flex;
  flex-direction: column;
  gap: 0.2em;
  min-width: 0;

  small { color: rgba(255, 255, 255, 0.55); font-size: 0.74em; line-height: 1.35; }
}

.lmm-policy-title {
  font-size: 0.9em;
  font-weight: 800;
}

.lmm-policy-outcome {
  margin-top: 0.15em;
  color: $accent;
  font-size: 0.72em;
  font-weight: 700;
}

.lmm-recommended {
  display: inline-block;
  margin-left: 0.35em;
  padding: 0.1em 0.4em;
  border-radius: 999px;
  color: #10131a;
  background: $accent;
  font-size: 0.62em;
  font-style: normal;
  font-weight: 900;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  vertical-align: 0.15em;
}

@media (max-width: 900px) {
  .lmm-policy { grid-template-columns: 1fr; }
}

/* ── Result step ────────────────────────────────────────────────────── */

.lmm-done {
  display: flex;
  align-items: flex-start;
  gap: 0.8em;
  padding: 0.85em 1em;
  border: 1px solid rgba(74, 222, 128, 0.35);
  border-radius: 10px;
  background: rgba(74, 222, 128, 0.08);
}

.lmm-done-icon {
  display: grid;
  place-items: center;
  flex: 0 0 auto;
  width: 1.9em;
  height: 1.9em;
  border-radius: 50%;
  background: $ok;
  color: #08130c;
  font-weight: 900;
}

.lmm-done-label {
  color: $ok;
  font-size: 0.7em;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.lmm-done-name {
  margin: 0.1em 0;
  font-size: 1.1em;
  font-weight: 800;
  word-break: break-word;
}

.lmm-done-sub {
  color: $muted;
  font-size: 0.8em;
}

.lmm-stats--4 { grid-template-columns: repeat(4, 1fr); }

.lmm-notes {
  border: 1px solid rgba(71, 85, 105, 0.35);
  border-radius: 10px;
  background: rgba(15, 23, 42, 0.4);
  overflow: hidden;
}

.lmm-note-group + .lmm-note-group { border-top: 1px solid rgba(71, 85, 105, 0.35); }

.lmm-note-group-title {
  padding: 0.5em 0.9em;
  background: rgba(2, 5, 12, 0.4);
  color: $muted;
  font-size: 0.7em;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.lmm-note-row {
  padding: 0.6em 0.9em;
  border-top: 1px solid rgba(71, 85, 105, 0.22);
}

.lmm-note-head {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.35em 0.6em;
}

.lmm-note-text {
  color: rgba(255, 255, 255, 0.82);
  font-size: 0.84em;
  line-height: 1.4;
}

.lmm-code {
  padding: 0.12em 0.45em;
  border: 1px solid rgba(148, 163, 184, 0.28);
  border-radius: 5px;
  background: rgba(2, 5, 12, 0.7);
  color: #fdba74;
  font-family: Consolas, "Roboto Mono", monospace;
  font-size: 0.8em;
  white-space: nowrap;
}

.lmm-path {
  margin-top: 0.3em;
  color: rgba(255, 255, 255, 0.45);
  font-family: Consolas, "Roboto Mono", monospace;
  font-size: 0.72em;
  line-height: 1.5;
  overflow-wrap: anywhere;
}

.lmm-path-sep {
  margin: 0 0.35em;
  color: rgba(255, 122, 26, 0.6);
}

.lmm-footnote {
  margin: 0.5em 0 0;
  color: $muted;
  font-size: 0.74em;
}
</style>
