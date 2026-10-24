<!-- Filters control, house style: a neutral Filters button (glyph + count pill) opening a compact
     near-black panel as wide as the toolbar. Two rows of filter fields (Price, Year, Mileage, Power,
     Weight / Body, Make, Drivetrain, Transmission, Fuel): faint caption over the current choice
     ("Any", "Up to 58,000", "RWD, AWD", "3 makes"). A field opens a small popover under it with the
     control: Min / Max house sliders with number boxes for ranges ("Can afford" in Price), checkbox
     chips built from the values the shop data actually has for choices. One popover at a time. A
     footer row holds Hide sold, the live vehicle count and Clear all. Every change applies at once
     through the same add-filter / remove-filter events; the active filters also show as removable
     chips under the toolbar (VehicleList). Outside click / Escape closes the popover, then the panel. -->
<template>
  <div class="filter-dropdown" ref="rootEl">
    <HouseButton class="filter-btn" :class="{ active: isOpen }" :icon="icons.filter" @click="togglePanel">
      Filters
      <span v-if="activeCount > 0" class="pill count-pill">{{ activeCount }}</span>
    </HouseButton>

    <Teleport to="body">
      <!-- controller: the open panel is its own scope (the d-pad stays inside); B closes an open field
           popover first (focus back on that field), then the panel (focus back on Filters) -->
      <div
        class="rls-house filter-panel"
        v-show="isOpen"
        v-bng-scoped-nav="panelScope"
        v-bng-on-ui-nav:back,menu="onNavBack"
        @click.stop
        @click.capture="dropRepeatClick"
        @focusin="onPanelFocusIn"
        @focusout="onPanelFocusOut"
        ref="panelEl">
        <div v-if="isOpen" class="field-grid">
          <div
            v-for="(f, i) in fields"
            :key="f.key"
            class="field-wrap"
            :class="{ open: openField === f.key, 'pop-right': i % 5 >= 3 }">
            <button
              type="button"
              class="filter-field"
              bng-nav-item
              :bng-no-nav="f.disabled ? 'true' : undefined"
              :data-field="f.key"
              :class="{ set: !f.summary.any, open: openField === f.key }"
              :disabled="f.disabled"
              :aria-expanded="openField === f.key"
              @click="toggleField(f.key)">
              <span class="field-caption">{{ f.label }}</span>
              <span class="field-value">
                <span v-if="f.summary.pre" class="field-pre">{{ f.summary.pre }}</span>
                <span :class="{ money: f.summary.money }"><BngIcon v-if="f.summary.money" class="cur" :type="icons.beamCurrency" />{{ f.summary.text }}</span>
              </span>
              <BngIcon class="field-chev" :type="icons.arrowSmallDown" />
            </button>

            <!-- popover: the control for this filter. Its own scope on the pad: the d-pad stays inside
                 it (it used to wander off to the fields beside it), B closes it back onto its field -->
            <div
              v-if="openField === f.key"
              class="field-pop"
              :class="f.kind"
              v-bng-scoped-nav="popScope"
              v-bng-on-ui-nav:back,menu="onNavBack">
              <section class="filter-group" :class="{ active: fieldHasValue(f) }">
                <div class="group-head">
                  <span class="group-title">{{ f.label }}</span>
                  <span v-if="isAffordField(f) || fieldHasValue(f)" class="group-right">
                    <HouseSwitch v-if="isAffordField(f)" :model-value="canAfford" class="afford-switch" @update:model-value="setCanAfford">
                      {{ racingTeamVehicleShop ? "Team budget" : "Can afford" }}
                      <span class="money-amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatNumber(filterBudgetMoney) }}</span>
                    </HouseSwitch>
                    <HouseButton v-else variant="quiet" compact class="pop-reset" @click="clearField(f)">Clear</HouseButton>
                  </span>
                </div>
                <div class="group-body">
                  <template v-if="f.kind === 'range'">
                    <div class="range-row">
                      <span class="range-end">Min</span>
                      <HouseSlider
                        with-input
                        input-type="text"
                        :input-formatter="v => formatRangeInput(f.range, v)"
                        :input-parser="v => parseRangeInput(f.range, v)"
                        :model-value="f.range.lo"
                        :min="f.range.bounds.min"
                        :max="f.range.hi"
                        :step="f.range.step"
                        @update:model-value="v => setRangeEnd(f.range, 'lo', v)" />
                    </div>
                    <div class="range-row">
                      <span class="range-end">Max</span>
                      <HouseSlider
                        with-input
                        input-type="text"
                        :input-formatter="v => formatRangeInput(f.range, v)"
                        :input-parser="v => parseRangeInput(f.range, v)"
                        :model-value="f.range.hi"
                        :min="f.range.lo"
                        :max="rangeTop(f.range)"
                        :step="f.range.step"
                        @update:model-value="v => setRangeEnd(f.range, 'hi', v)" />
                    </div>
                  </template>
                  <div v-else class="chips choice-chips scroll" v-bng-ui-nav-scroll>
                    <button
                      v-for="opt in f.options"
                      :key="opt"
                      type="button"
                      bng-nav-item
                      :class="{ active: isSelected(f.key, opt) }"
                      :aria-pressed="isSelected(f.key, opt)"
                      @click="toggleChoice(f, opt)">
                      <BngIcon v-if="isSelected(f.key, opt)" class="chip-check" :type="icons.checkmark" />
                      {{ opt }}
                    </button>
                  </div>
                </div>
              </section>
            </div>
          </div>
        </div>

        <div class="panel-foot">
          <HouseSwitch v-model="hideSold" class="hide-sold">Hide sold vehicles</HouseSwitch>
          <span class="panel-count">{{ matchCount }} {{ matchCount === 1 ? "vehicle" : "vehicles" }}</span>
          <HouseButton v-if="activeCount > 0" variant="quiet" compact @click="clearAllFilters">Clear all</HouseButton>
          <HouseButton variant="quiet" compact class="close-btn" :icon="icons.xmark" title="Close" @click="closePanel(true)" />
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { useDropdown } from "../../composables/useDropdown.js"
import { useCefTyping } from "../../composables/useCefTyping.js"
import { safeLua } from "../../utils/safeLua.js"

import { ref, reactive, computed, watch, onMounted, onBeforeUnmount, Teleport, nextTick } from "vue"
import { vBngScopedNav, vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { setFocus } from "@/services/uiNavFocus"
import { useRoute } from "vue-router"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton, HouseSlider, HouseSwitch } from "../house/index.js"
import { lua, useBridge } from "@/bridge"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { METERS_PER_MILE, shopFilterUnit } from "../../utils/units"

// Props
const props = defineProps({
  filters: {
    type: Object,
    default: () => ({}),
  },
  // the list's own count (dealer + search + filters), so the panel agrees with the header
  matchCount: {
    type: Number,
    default: null,
  },
})

// Emits
const emit = defineEmits(["update:filters", "add-filter", "remove-filter", "clear-filters"])

// State
const isOpen = ref(false)
const openField = ref(null) // key of the field whose popover is open
const rootEl = ref(null)
const panelEl = ref(null)

const route = useRoute()
const vehicleShoppingStore = useVehicleShoppingStore?.() || null
const racingTeamVehicleShop = computed(() => {
  const q = route.query.rtBiz
  return (q !== undefined && q !== null && String(q) !== "") || !!vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessId
})

// Vehicle data for dynamic bounds: every listing, before filters and search, so the slider ends
// stay put while filters narrow the list
const allVehicles = computed(() => {
  const list = vehicleShoppingStore?.vehicleShoppingData?.vehiclesInShop
  if (!list) return []
  return Array.isArray(list) ? list : Object.values(list)
})

// How many vehicles the current filters (and search) leave in the list
const matchCount = computed(() =>
  typeof props.matchCount === "number" ? props.matchCount : (vehicleShoppingStore?.filteredVehicles || []).length
)

// Personal wallet from store (nil in payload during racing-team shop; filter row uses filterBudgetMoney there).
const playerMoney = computed(() => Number((vehicleShoppingStore?.vehicleShoppingData?.playerAttributes?.money && (vehicleShoppingStore.vehicleShoppingData.playerAttributes.money.value ?? vehicleShoppingStore.vehicleShoppingData.playerAttributes.money)) || 0))

const filterBudgetMoney = computed(() => {
  if (racingTeamVehicleShop.value) {
    const v = vehicleShoppingStore?.vehicleShoppingData?.racingTeamBusinessMoney
    return Number.isFinite(Number(v)) ? Number(v) : 0
  }
  return playerMoney.value
})

const getBounds = (key, fallbackMin, fallbackMax) => computed(() => {
  const list = allVehicles.value
  if (!list || list.length === 0) return { min: fallbackMin, max: fallbackMax }
  let min = Infinity, max = -Infinity
  for (const v of list) {
    // price: the dealer-adjusted price the cards show and the store filters on
    const val = Number(key === "Value" && Number(v?.valueAdjusted) > 0 ? v.valueAdjusted : v?.[key])
    if (!Number.isFinite(val)) continue
    if (val < min) min = val
    if (val > max) max = val
  }
  if (!Number.isFinite(min)) min = fallbackMin
  if (!Number.isFinite(max)) max = fallbackMax
  return { min, max }
})

// Bounds snap outward to the slider step so the extremes always include every vehicle
const snapBounds = (raw, step, scale = 1) => computed(() => {
  const min = Number(raw.value.min) / scale
  const max = Number(raw.value.max) / scale
  const lo = Number.isFinite(min) ? Math.floor(min / step) * step : 0
  let hi = Number.isFinite(max) ? Math.ceil(max / step) * step : step
  if (hi <= lo) hi = lo + step
  return { min: lo, max: hi }
})

const priceBounds = snapBounds(getBounds("Value", 0, 100000), 1000)
const yearBounds = snapBounds(getBounds("year", 1980, 2024), 1)
// mileage / power / weight sliders run in the player's units; the store converts back to the listing's
const { units } = useBridge()
const mileageUnit = shopFilterUnit(units, "Mileage")
const powerUnit = shopFilterUnit(units, "Power")
const weightUnit = shopFilterUnit(units, "Weight")
const mileageBounds = snapBounds(getBounds("Mileage", 0, 300000 * METERS_PER_MILE), 1000, mileageUnit.dataPerUnit)
const powerBounds = snapBounds(getBounds("Power", 50, 1000), 10, powerUnit.dataPerUnit)
const weightBounds = snapBounds(getBounds("Weight", 0, 10000), 10, weightUnit.dataPerUnit)

// ---- ranges: Min / Max follow the store filter (or the data bounds when none is set)
function makeRange(key, label, bounds, step, unit) {
  const r = reactive({
    key,
    label,
    step,
    unit,
    bounds,
    lo: bounds.value.min,
    hi: bounds.value.max,
    active: computed(() => {
      const f = props.filters?.[key]
      return !!f && (f.min !== undefined || f.max !== undefined)
    }),
  })
  watch(
    [() => props.filters?.[key], bounds],
    ([f, b]) => {
      // shown within the slider ends (a budget cap can sit above the dearest listing)
      r.lo = f && Number.isFinite(f.min) ? Math.min(Math.max(f.min, b.min), b.max) : b.min
      r.hi = f && Number.isFinite(f.max) ? Math.max(Math.min(f.max, b.max), b.min) : b.max
    },
    { immediate: true, deep: true }
  )
  return r
}

const priceRange = makeRange("Value", "Price", priceBounds, 1000, "")
const ranges = [
  priceRange,
  makeRange("year", "Year", yearBounds, 1, ""),
  makeRange("Mileage", "Mileage", mileageBounds, 1000, mileageUnit.label),
  makeRange("Power", "Power", powerBounds, 10, powerUnit.label),
  makeRange("Weight", "Weight", weightBounds, 10, weightUnit.label),
]

// "Can afford" caps the price range at the wallet (or team budget)
const canAfford = ref(false)
const priceCap = computed(() => Math.max(priceBounds.value.min, Math.min(filterBudgetMoney.value, priceBounds.value.max)))
const rangeTop = r => (r.key === "Value" && canAfford.value ? priceCap.value : r.bounds.max)

const commitTimers = {}
function setRangeEnd(r, end, v) {
  const n = Number(v)
  if (!Number.isFinite(n)) return
  r[end] = n
  clearTimeout(commitTimers[r.key])
  commitTimers[r.key] = setTimeout(() => commitRange(r), 180)
}

// An end left at the data bound stays open, so the filter reads "up to" / "from" and keeps new stock.
function commitRange(r) {
  const b = r.bounds
  const lo = Math.min(r.lo, r.hi)
  const hi = Math.max(r.lo, r.hi)
  const min = lo > b.min ? lo : undefined
  let max = hi < b.max ? hi : undefined
  // "Can afford" with Max at the cap means "up to my budget", even when the budget tops every listing
  if (r.key === "Value" && canAfford.value) max = hi >= priceCap.value ? Math.max(b.min, filterBudgetMoney.value) : hi
  if (min === undefined && max === undefined) emit("remove-filter", r.key)
  else emit("add-filter", { category: r.key, type: "range", label: r.label, value: [min, max] })
}

function resetRange(r) {
  clearTimeout(commitTimers[r.key])
  if (r.key === "Value") canAfford.value = false
  emit("remove-filter", r.key)
}

function setCanAfford(on) {
  canAfford.value = !!on
  priceRange.hi = on ? Math.min(priceRange.hi, priceCap.value) : priceBounds.value.max
  commitRange(priceRange)
}

// The price filter was removed elsewhere (chip, Clear all): the switch follows
watch(
  () => props.filters?.Value,
  f => {
    if (!f || f.max === undefined) canAfford.value = false
  },
  { deep: true }
)

// ---- choices: chips from the values the vehicles for sale actually carry
const CHOICE_GROUPS = [
  { key: "Body Style", label: "Body", plural: "body styles" },
  { key: "Brand", label: "Make", plural: "makes" },
  { key: "Name", label: "Model", plural: "models" },
  { key: "Drivetrain", label: "Drivetrain", plural: "drivetrains" },
  { key: "Transmission", label: "Transmission", plural: "transmissions" },
  { key: "Fuel Type", label: "Fuel", plural: "fuels" },
]

const selectedValues = key => (props.filters?.[key]?.values || []).map(v => String(v))
const isSelected = (key, value) => selectedValues(key).includes(String(value))
const selectedCount = key => selectedValues(key).length

const choiceGroups = computed(() =>
  CHOICE_GROUPS.map(g => {
    const vals = vehicleShoppingStore?.fieldValues?.[g.key]
    const options = (Array.isArray(vals) ? vals : []).map(v => String(v)).filter(v => v.trim() !== "")
    // keep a picked value visible even if no listing carries it any more
    for (const s of selectedValues(g.key)) if (!options.includes(s)) options.push(s)
    return { ...g, options }
  })
)

function toggleChoice(g, value) {
  emit("add-filter", { category: g.key, type: "select", label: g.label, value, displayValue: value })
}
function clearChoice(key) {
  emit("remove-filter", key)
}

// what the popover header acts on: a range is set once it is active, a choice once something is picked
const fieldHasValue = f => (f.kind === "range" ? f.range.active : selectedCount(f.key) > 0)
const isAffordField = f => f.kind === "range" && f.key === "Value"
const clearField = f => (f.kind === "range" ? resetRange(f.range) : clearChoice(f.key))

// ---- field summaries: "Any", "Up to 58,000", "1989–2022", "RWD, AWD", "3 makes"
function rangeSummary(r) {
  const f = props.filters?.[r.key]
  const hasMin = !!f && Number.isFinite(f.min)
  const hasMax = !!f && Number.isFinite(f.max)
  if (!hasMin && !hasMax) return { any: true, pre: "", text: "Any" }
  const n = v => (r.key === "year" ? String(v) : formatNumber(v))
  const unit = r.unit ? ` ${r.unit}` : ""
  const money = r.key === "Value"
  if (hasMin && hasMax) return { pre: "", text: `${n(f.min)}–${n(f.max)}${unit}`, money }
  if (hasMax) return { pre: "Up to", text: `${n(f.max)}${unit}`, money }
  return { pre: "From", text: `${n(f.min)}${unit}`, money }
}
function choiceSummary(g) {
  const sel = selectedValues(g.key)
  if (!g.options.length) return { any: true, pre: "", text: "None listed" }
  if (!sel.length) return { any: true, pre: "", text: "Any" }
  if (sel.length <= 2) return { pre: "", text: sel.join(", ") }
  return { pre: "", text: `${sel.length} ${g.plural}` }
}

const fields = computed(() => [
  ...ranges.map(r => ({ kind: "range", key: r.key, label: r.label, range: r, summary: rangeSummary(r) })),
  ...choiceGroups.value.map(g => ({ kind: "choice", key: g.key, label: g.label, plural: g.plural, options: g.options, disabled: !g.options.length, summary: choiceSummary(g) })),
])

function toggleField(key) {
  openField.value = openField.value === key ? null : key
  // controller: step into the opened popover, onto its first control. A slider is entered the game's
  // way (land on it, A to adjust, A / B to finish): focusing its inner range input skipped its scope
  if (openField.value) {
    // a slider only becomes focusable once its scope directive has set it up, so keep trying for a
    // few frames until focus is inside the popover
    const key = openField.value
    let tries = 0
    const enter = () => {
      if (openField.value !== key) return
      const pop = panelEl.value?.querySelector(".field-wrap.open .field-pop")
      if (!pop || pop.contains(document.activeElement)) return
      // the game's focus call: a slider's container is a div with no tabindex, so el.focus() did nothing
      const first = pop.querySelector('[bng-nav-item]:not([bng-no-nav="true"]):not([disabled]), .bng-slider-container')
      if (first) setFocus(first)
      if (!pop.contains(document.activeElement) && ++tries < 10) requestAnimationFrame(enter)
    }
    nextTick(enter)
  }
}

// ---- controller: the panel is a container scope like the Sort panel; back / menu never bubble up to
// the shop (which would leave it). ok stays here too: the scope already turns it into a click on the
// focused control, and letting it bubble made the game's global handler click a second time, so one A
// press opened a field and shut it again in the same tick (in game the shop's route scope is active)
const panelScope = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}
// the open popover, same rules one level in (ok bubbling to the panel scope would click twice again)
const popScope = { ...panelScope }
const triggerEl = () => rootEl.value?.querySelector(".filter-btn")
function closePanel(refocus = false) {
  const trigger = triggerEl()
  // the shop scope resumes on its autofocus item (else its first one, a dealer section), so mark the
  // trigger as that item while the panel closes, then focus it once the scope has settled
  if (refocus) trigger?.setAttribute("bng-scoped-nav-autofocus", "")
  isOpen.value = false
  if (refocus) {
    // the first resume after entering the shop lands later than the next ones, so check a few times
    // over ~400 ms (too short for a deliberate d-pad move to be overridden)
    const settle = [60, 200, 400]
    nextTick(() =>
      settle.forEach((ms, i) =>
        setTimeout(() => {
          if (!isOpen.value && trigger && document.activeElement !== trigger) trigger.focus()
          if (i === settle.length - 1) trigger?.removeAttribute("bng-scoped-nav-autofocus")
        }, ms)
      )
    )
  }
}
const { toggle: togglePanel } = useDropdown({
  open: isOpen,
  closeOnToggle: () => closePanel(false),
  // The open-state watcher owns placement and resize/scroll listeners.
  positionTiming: "caller",
  afterOpen: () => {
    panelEl.value?.querySelector(".filter-field:not([disabled])")?.focus()
  },
})
// One controller A press reached a chip as two synthetic clicks (seen in the Atlas), so a toggle
// switched on and straight back off. Drop an identical synthetic click on the same element within
// 60 ms; real presses and mouse clicks are never that close together.
let lastSyntheticClick = { el: null, t: 0 }
function dropRepeatClick(e) {
  if (e.isTrusted) return
  const now = performance.now()
  if (lastSyntheticClick.el === e.target && now - lastSyntheticClick.t < 60) {
    e.stopImmediatePropagation()
    e.preventDefault()
    return
  }
  lastSyntheticClick = { el: e.target, t: now }
}

function onNavBack() {
  if (openField.value) {
    const key = openField.value
    openField.value = null
    nextTick(() => panelEl.value?.querySelector(`.filter-field[data-field="${key}"]`)?.focus())
  } else {
    closePanel(true)
  }
  return false
}

// Sync hideSold with active filters
const hideSold = computed({
  get: () => {
    const filter = props.filters?.hideSold
    if (!filter) return false
    return filter.value === true ||
      (filter.values && filter.values.length > 0 && (filter.values[0] === true || filter.values[0] === "true"))
  },
  set: val => {
    if (val) {
      emit("add-filter", {
        category: "hideSold",
        type: "boolean",
        label: "Hide Sold",
        value: true,
        displayValue: "Hide Sold Vehicles",
      })
    } else {
      emit("remove-filter", "hideSold")
    }
  },
})

// One per range, one per picked value, one for hide sold (matches the chips under the toolbar)
const activeCount = computed(() =>
  Object.entries(props.filters || {}).reduce((n, [key, f]) => {
    if (!f) return n
    if (key === "hideSold") return n + (hideSold.value ? 1 : 0)
    let c = 0
    if (f.min !== undefined || f.max !== undefined) c++
    if (Array.isArray(f.values)) c += f.values.length
    return n + c
  }, 0)
)

// Safe format for numbers displayed in labels
const formatNumber = val => {
  const n = typeof val === "number" ? val : Number(val)
  if (Number.isFinite(n)) return n.toLocaleString(undefined, { maximumFractionDigits: 0 })
  return "0"
}

// Number boxes in the range popovers: grouped like the summaries ("251,000"), year left plain.
// Text input so the grouping shows; typing is read back strictly in the same locale and kept within
// the slider ends. Anything that isn't a well-formed number is rejected (NaN), so BngSlider puts the
// previous value back instead of guessing (the old digits-only read turned "550.5" into 5505 and
// "-100" into 100).
const formatRangeInput = (r, v) => (r.key === "year" ? String(Math.round(Number(v) || 0)) : formatNumber(v))
const numberSeparators = (() => {
  const parts = new Intl.NumberFormat(undefined).formatToParts(12345.6)
  return {
    group: parts.find(p => p.type === "group")?.value ?? ",",
    decimal: parts.find(p => p.type === "decimal")?.value ?? ".",
  }
})()
const escapeRe = c => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
const parseLocaleNumber = text => {
  const { group, decimal } = numberSeparators
  // spaces as grouping too (some locales group with a (narrow) no-break space; people type a plain one)
  const g = "(?:" + escapeRe(group) + String.raw`|[\s\u00a0\u202f])`
  const d = escapeRe(decimal)
  // optional sign; digits either ungrouped or grouped in threes; optional decimal part
  const re = new RegExp(String.raw`^([+-]?)(\d+|\d{1,3}(?:` + g + String.raw`\d{3})+)(?:` + d + String.raw`(\d+))?$`)
  const m = text.match(re)
  if (!m) return NaN
  const whole = m[2].replace(new RegExp(g, "g"), "")
  const value = Number(whole + (m[3] ? "." + m[3] : ""))
  return m[1] === "-" ? -value : value
}
const parseRangeInput = (r, s) => {
  const text = String(s ?? "").trim()
  if (!text) return NaN // blank: BngSlider restores the box (null would read as 0)
  const value = parseLocaleNumber(text)
  if (!Number.isFinite(value)) return NaN
  if (r.key === "year" && !Number.isInteger(value)) return NaN // "2004.5" is not a year
  // filters run in whole units; a typed decimal rounds to the nearest one, then the range bounds apply
  return Math.min(Math.max(Math.round(value), r.bounds.min), rangeTop(r))
}

const clearAllFilters = () => {
  canAfford.value = false
  emit("clear-filters")
}

// Position the panel under the toolbar, as wide as the toolbar, kept on screen.
function positionPanel() {
  if (!rootEl.value || !panelEl.value) return
  const trigger = rootEl.value.querySelector(".filter-btn")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const bar = rootEl.value.closest(".search-filter-bar") || rootEl.value
  const barRect = bar.getBoundingClientRect()
  const el = panelEl.value
  const margin = 12
  el.style.position = "fixed"
  el.style.top = `${rect.bottom + 6}px`
  el.style.width = `${Math.min(barRect.width, window.innerWidth - 2 * margin)}px`
  const width = el.offsetWidth || barRect.width
  let left = barRect.left
  left = Math.min(left, window.innerWidth - width - margin)
  el.style.left = `${Math.max(margin, left)}px`
}

// Watch for open state to position panel
watch(isOpen, async newVal => {
  if (newVal) {
    await nextTick()
    positionPanel()
    window.addEventListener("resize", positionPanel)
    window.addEventListener("scroll", positionPanel)
  } else {
    openField.value = null
    window.removeEventListener("resize", positionPanel)
    window.removeEventListener("scroll", positionPanel)
  }
})

// Outside click: closes the open popover first, then the panel; inside the panel, a click outside
// the open field (its button and popover) closes just the popover.
function onDocClick(e) {
  if (!rootEl.value || !panelEl.value) return
  if (!rootEl.value.contains(e.target) && !panelEl.value.contains(e.target)) {
    if (openField.value) openField.value = null
    else isOpen.value = false
    return
  }
  if (openField.value && panelEl.value.contains(e.target)) {
    // compare keys, not the wrap's "open" class: that class only renders on the next tick, so a click
    // right after opening read as "outside" and shut the popover it had just opened
    const key = e.target.closest?.(".field-wrap")?.querySelector(".filter-field")?.dataset.field
    if (key !== openField.value) openField.value = null
  }
}
// Escape: popover first, then the panel

onMounted(() => {
  document.addEventListener("click", onDocClick, true)
})
onBeforeUnmount(() => {
  document.removeEventListener("click", onDocClick, true)
  window.removeEventListener("resize", positionPanel)
  window.removeEventListener("scroll", positionPanel)
  Object.values(commitTimers).forEach(t => clearTimeout(t))
})

// Typing mode only while a number box inside the panel has focus. It used to switch on for as long as
// the panel was open, which handed every input to typing and left a controller unable to use the panel.
const cefTyping = useCefTyping()
const setTyping = on => on ? cefTyping.onFocus() : cefTyping.onBlur()
const isTextField = el => el?.tagName === "INPUT" && el.type !== "range" && el.type !== "checkbox"
let typing = false
function onPanelFocusIn(e) {
  if (isTextField(e.target) && !typing) {
    typing = true
    setTyping(true)
  }
}
function onPanelFocusOut(e) {
  if (typing && isTextField(e.target) && !isTextField(e.relatedTarget)) {
    typing = false
    setTyping(false)
  }
}
watch(isOpen, open => {
  if (!open && typing) {
    typing = false
    setTyping(false)
  }
})
onBeforeUnmount(() => {
  if (typing) setTyping(false)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.filter-dropdown {
  display: flex;
  align-items: center;
  position: relative;
}

/* neutral trigger with a count pill */
.filter-btn {
  .count-pill {
    margin-left: 0.1em;
    padding: 0.38em 0.45em 0.12em;
    font-size: 0.78em;
    background: var(--panel-hover);
    color: #fff;
    font-variant-numeric: tabular-nums;
  }
  &.active {
    background: var(--panel-hover);
  }
}

/* house menu panel (teleported to body, so it carries its own scaled font); popovers may hang
   below it, so no overflow clipping */
.filter-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  z-index: 12000;
  width: 60em;
  max-width: calc(100vw - 24px);
  display: grid;
  gap: 0.55em;
  padding: 0.75em 0.75em 0.5em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
}

/* two rows of five fields */
.field-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 0.5em;
}
.field-wrap {
  position: relative;
  min-width: 0;
  &.open {
    z-index: 2;
  }
}

/* one field: faint caption over the current choice, chevron on the right */
.filter-field {
  appearance: none;
  position: relative;
  display: grid;
  align-content: start;
  gap: 0.3em;
  width: 100%;
  height: 100%;
  margin: 0;
  padding: 0.6em 1.9em 0.5em 0.75em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover:not(:disabled),
  &.open {
    background: rgba(255, 255, 255, 0.07);
  }
  &.focus-visible {
    outline: none;
    box-shadow: var(--focus);
  }
  &:disabled {
    opacity: 0.45;
    cursor: default;
  }
}
.field-caption {
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.07em;
  line-height: 1;
  text-transform: uppercase;
}
.field-value {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0 0.3em;
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 700;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
  .money {
    color: var(--money);
  }
}
.filter-field.set .field-value {
  color: #fff;
  .money {
    color: var(--money);
  }
}
.field-pre {
  color: var(--faint);
  font-weight: 600;
}
.field-chev {
  position: absolute;
  right: 0.65em;
  top: 50%;
  font-size: 1em;
  color: var(--faint);
  transform: translateY(-50%);
  transition: transform 0.12s;
}
.filter-field.open .field-chev {
  transform: translateY(-50%) rotate(180deg);
}

/* popover under its field (right-aligned for the last columns so it stays inside the panel) */
.field-pop {
  position: absolute;
  top: calc(100% + 0.4em);
  left: 0;
  width: 22em;
  max-width: calc(100vw - 24px);
  padding: 0.7em 0.75em 0.8em;
  border-radius: var(--radius-control);
  background: #222225;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.1), 0 12px 28px rgba(0, 0, 0, 0.55);
  &.choice {
    width: 19em;
  }
}
.field-wrap.pop-right .field-pop {
  left: auto;
  right: 0;
}
/* one labelled group inside the popover: caption title left, optional header control right, then the
   controls; set (something chosen) brightens the caption */
.filter-group {
  display: grid;
  gap: 0.5em;
  min-width: 0;
}
.group-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.6em;
  min-height: 1.7em;
}
.group-title {
  flex: 1 1 auto;
  min-width: 0;
  padding-top: 0.15em;
  font-size: 0.78em;
  font-weight: 700;
  letter-spacing: 0.06em;
  line-height: 1;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.55);
  transition: color 0.12s;
}
.filter-group.active .group-title {
  color: #fff;
}
.group-right {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
}
.group-body {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-width: 0;
}
.pop-reset {
  font-size: 0.85em;
  margin: -0.3em -0.4em -0.3em 0;
}

/* footer: hide sold left, count + Clear all + close right */
.panel-foot {
  display: flex;
  align-items: center;
  gap: 0.5em;
  min-height: 2.4em;
  padding-left: 0.2em;
}
.hide-sold {
  font-size: 0.92em;
  margin-right: auto;
}
.panel-count {
  padding: 0.15em 0.3em 0;
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  line-height: 1;
  font-variant-numeric: tabular-nums;
}

/* range: Min / Max rows, short end label then the house slider with its number box */
.range-row {
  display: grid;
  grid-template-columns: 2.6em minmax(0, 1fr);
  align-items: center;
  /* neutral fill: the screen keeps its one orange element elsewhere */
  :deep(.house-slider) {
    --accent: rgba(255, 255, 255, 0.5);
  }
}
.range-end {
  padding-top: 0.1em;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 700;
}

/* "Can afford" switch in the price popover header: budget in gold */
.afford-switch {
  font-size: 0.85em;
  color: var(--muted);
  .money-amount {
    margin-left: 0.3em;
    color: var(--money);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}
.cur {
  font-size: 0.95em;
  margin-right: 0.1em;
  transform: translateY(0.08em);
}

/* choices: house chips, picked ones lifted with a check glyph; long lists scroll inside */
.choice-chips {
  max-height: 15em;
  align-content: flex-start;
  overflow-y: auto;
}
.choice-chips > button {
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  font-size: 0.92em;
  &.active {
    background: var(--panel-hover);
    color: #fff;
  }
}
.chip-check {
  font-size: 0.95em;
  margin: -0.1em 0 0 -0.15em;
}
</style>
