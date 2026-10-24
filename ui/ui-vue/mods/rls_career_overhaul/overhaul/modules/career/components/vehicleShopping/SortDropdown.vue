<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Sort control, house style: a neutral button naming the current order ("Price, low to high")
     with a chevron, opening a compact near-black menu: a direction toggle on top (worded per field:
     Oldest / Newest, Nearest / Farthest, Low to high / High to low), then one single-line row per sort
     field with a check on the current one. Picking a field keeps the direction. Same store calls
     (store.setSort(field, direction)). -->
<template>
  <div class="sort-dropdown" ref="rootEl">
    <HouseButton class="sort-btn" :class="{ active: isOpen }" :icon="icons.sortAsc" title="Sort" @click="toggle">
      <span class="sort-current">{{ activeLabel }}</span>
      <BngIcon class="chev" :type="icons.arrowSmallDown" />
    </HouseButton>

    <Teleport to="body">
      <!-- controller: the open panel is its own scope (the d-pad stays inside), B / Start close it and
           give focus back to the trigger instead of leaving the shop -->
      <div
        class="rls-house sort-panel"
        v-show="isOpen"
        v-bng-scoped-nav="panelScope"
        v-bng-on-ui-nav:back,menu="onNavBack"
        @click.stop
        ref="panelEl">
        <div class="seg bar dir-toggle">
          <button
            v-for="d in DIRECTIONS"
            :key="d"
            type="button"
            bng-nav-item
            :class="{ active: currentDir === d }"
            :aria-pressed="currentDir === d"
            @click="setDirection(d)">
            {{ dirShort(currentField, d) }}
          </button>
        </div>

        <div class="options">
          <HouseButton
            v-for="opt in sortFields"
            :key="opt.field"
            variant="menu"
            class="option"
            :class="{ selected: opt.field === currentField }"
            :aria-pressed="opt.field === currentField"
            @click="applyField(opt.field)">
            <span class="option-label">{{ opt.label }}</span>
            <BngIcon v-if="opt.field === currentField" class="option-check" :type="icons.checkmark" />
          </HouseButton>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<script setup>
import { useDropdown } from "../../composables/useDropdown.js"
import { computed, ref, onMounted, onBeforeUnmount, Teleport, nextTick, watch } from "vue"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { useVehicleShoppingStore } from "../../stores/vehicleShoppingStore"
import { vBngScopedNav, vBngOnUiNav } from "@/common/directives"

const store = useVehicleShoppingStore()
const isOpen = ref(false)
const rootEl = ref(null)
const panelEl = ref(null)

const DIRECTIONS = ["asc", "desc"]

// Sort fields in menu order. Price sorts on the dealer-adjusted price (the store's getFieldValue maps
// 'Value' to valueAdjusted), so "Adjusted price" is not listed separately. Market value: the
// buy-multiplier-adjusted figure when the data has it, else the plain one.
const FIELD_ORDER = [
  { field: "Value", label: "Price" },
  { field: "year", label: "Year" },
  { field: "Mileage", label: "Mileage" },
  { field: "Power", label: "Power" },
  { field: "Weight", label: "Weight" },
  { field: "distance", label: "Distance" },
  { field: "quickTravelPrice", label: "Taxi fare" },
  { field: ["marketValueAdjusted", "marketValue"], label: "Market value" },
  { field: "deliveryDiscount", label: "Delivery discount" },
]

const sortFields = computed(() => {
  const fields = Array.isArray(store.numericFields) ? store.numericFields : []
  const out = []
  for (const def of FIELD_ORDER) {
    const candidates = Array.isArray(def.field) ? def.field : [def.field]
    // Price always shows (it is the default order); the rest only when the listings carry them
    const field = def.field === "Value" ? "Value" : candidates.find(f => fields.includes(f))
    if (field) out.push({ field, label: def.label })
  }
  // an order chosen earlier on a field no longer listed still shows as current
  const cur = store.sortField || "Value"
  if (!out.some(o => o.field === cur)) out.push({ field: cur, label: fieldName(cur) })
  return out
})

function fieldName(field) {
  for (const def of FIELD_ORDER) {
    if (def.field === field || (Array.isArray(def.field) && def.field.includes(field))) return def.label
  }
  const words = String(field || "").replace(/_/g, " ").replace(/([a-z0-9])([A-Z])/g, "$1 $2").trim()
  return words.charAt(0).toUpperCase() + words.slice(1).toLowerCase()
}

// Direction wording per field
function dirShort(field, dir) {
  if (field === "year") return dir === "asc" ? "Oldest" : "Newest"
  if (field === "distance") return dir === "asc" ? "Nearest" : "Farthest"
  return dir === "asc" ? "Low to high" : "High to low"
}
function dirPhrase(field, dir) {
  if (field === "year") return dir === "asc" ? "oldest first" : "newest first"
  if (field === "distance") return dir === "asc" ? "nearest first" : "farthest first"
  return dir === "asc" ? "low to high" : "high to low"
}

const currentField = computed(() => store.sortField || "Value")
const currentDir = computed(() => (store.sortDirection === "desc" ? "desc" : "asc"))
const activeLabel = computed(() => `${fieldName(currentField.value)}, ${dirPhrase(currentField.value, currentDir.value)}`)

// Direction: re-sort right away, menu stays open
const setDirection = dir => store.setSort(currentField.value, dir)
// Field: keep the current direction, close the menu
const applyField = field => {
  store.setSort(field, currentDir.value)
  close(true)
}

// same shape as HouseMenu's list: a container scope focus cannot leave; back / menu never bubble up to
// the shop (which would leave it); ok stays too, or one A press clicked the focused row twice
const panelScope = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}
const triggerEl = () => rootEl.value?.querySelector(".sort-btn")
function close(refocus = false) {
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
function onNavBack() {
  close(true)
  return false
}
// opening moves focus onto the current sort field so the d-pad starts inside the panel
const { toggle: toggle } = useDropdown({
  open: isOpen,
  closeOnToggle: () => close(false),
  // The open-state watcher owns placement and resize/scroll listeners.
  positionTiming: "caller",
  afterOpen: () => {
    const current = panelEl.value?.querySelector(".option.selected") || panelEl.value?.querySelector("button")
    current?.focus()
  },
})

// Position panel under the trigger, right edges aligned, kept on screen
function positionPanel() {
  if (!rootEl.value || !panelEl.value) return
  const trigger = rootEl.value.querySelector(".sort-btn")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const el = panelEl.value
  const margin = 12
  const top = rect.bottom + 6
  el.style.position = "fixed"
  el.style.top = `${top}px`
  el.style.maxHeight = `${Math.max(160, window.innerHeight - top - margin)}px`
  const width = el.offsetWidth || 0
  let left = rect.right - width
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
    window.removeEventListener("resize", positionPanel)
    window.removeEventListener("scroll", positionPanel)
  }
})

// local click-outside / Escape to close
function onDocClick(e) {
  if (!rootEl.value || !panelEl.value) return
  if (!rootEl.value.contains(e.target) && !panelEl.value.contains(e.target)) {
    isOpen.value = false
  }
}

onMounted(() => {
  document.addEventListener("click", onDocClick, true)
})
onBeforeUnmount(() => {
  document.removeEventListener("click", onDocClick, true)
  window.removeEventListener("resize", positionPanel)
  window.removeEventListener("scroll", positionPanel)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.sort-dropdown {
  display: flex;
  position: relative;
}

/* neutral trigger: glyph, current order in words, chevron */
.sort-btn {
  .sort-current {
    white-space: nowrap;
  }
  .chev {
    margin-left: 0.1em;
    font-size: 1.05em;
    color: var(--faint);
    transform: translateY(0.05em);
    transition: transform 0.12s;
  }
  :deep(.btn-label) {
    display: inline-flex;
    align-items: center;
    gap: 0.35em;
    overflow: visible;
  }
  &.active {
    background: var(--panel-hover);
    .chev {
      transform: translateY(0.05em) rotate(180deg);
    }
  }
}

/* house menu panel (teleported, so it carries its own scaled font); sized to its rows */
.sort-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: fixed;
  z-index: 12000;
  width: max-content;
  min-width: 15em;
  max-width: calc(100vw - 24px);
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  overflow-y: auto;
  padding: 0.4em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
}

/* direction toggle: the house segmented bar, two equal halves */
.dir-toggle {
  flex: 0 0 auto;
  button {
    flex: 1 1 0;
    font-size: 0.88em;
    white-space: nowrap;
  }
}

/* one single-line row per field */
.options {
  display: flex;
  flex-direction: column;
  gap: 0.05em;
}
.option {
  flex: 0 0 auto;
  height: auto;
  padding-top: 0.55em;
  padding-bottom: 0.42em;
  :deep(.btn-label) {
    align-items: center;
    white-space: nowrap;
    line-height: 1.15;
  }
  .option-label {
    flex: 1 1 auto;
    white-space: nowrap;
  }
  .option-check {
    flex: 0 0 auto;
    margin-left: 1.2em;
    font-size: 1em;
  }
  &.selected {
    background: var(--panel);
    color: #fff;
    font-weight: 800;
  }
}
</style>
