<template>
  <ComputerWrapper :title="title" @back="confirmExit">
    <ComputerPanel
      ref="panelRef"
      v-bng-scoped-nav="{ scopeId: workshopScope, canDeactivate: tuningBack }"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      class="tuning-card rls-house"
      :active="isWorkshopActive"
    >
      <!-- no inner heading: the page title already says Tuning (context still switches to the cart) -->
      <div ref="actionRoot" class="inner-tuning-card">
        <div v-if="loading" class="state-message">Loading tuning data…</div>
        <div v-else-if="buckets.length" class="tuning-form" v-bng-ui-nav-scroll>
          <section v-for="category in buckets" :key="category.name" class="tuning-category">
            <h2 class="category-heading">{{ category.name }}</h2>
            <div v-for="subCategory in category.items" :key="subCategory.name" class="tuning-subcategory">
              <h3 v-if="subCategory.name !== 'Other'" class="subcategory-heading">{{ subCategory.name }}</h3>
              <BngRow v-for="variable in subCategory.items" :key="variable.name" vertical
                class="variable-box" :tooltip="variable.description">
                <template #label>{{ variable.title || variable.name }}</template>
                <HouseSlider
                  :min="variable.minDis"
                  :max="variable.maxDis"
                  :step="variable.stepDis"
                  :unit="variable.unit"
                  with-input
                  with-reset
                  :orig-value="variable.originalDisplay"
                  v-model="variable.valDis"
                  @valueChanged="onChange"
                />
              </BngRow>
            </div>
          </section>
        </div>
        <div v-else-if="!loading" class="state-message">No tuning options are available for this vehicle.</div>

        <div v-if="!loading" class="tuning-controls">
          <BusinessWheelData v-if="wheelDataVisible" class="wheel-data"
            :business-id="sessionStore.businessId" :vehicle-id="sessionStore.pulledOutVehicle?.vehicleId" />
          <div class="controls-row">
            <HouseSwitch v-model="wheelDataVisible">Live Wheel Data</HouseSwitch>
            <HouseSwitch v-model="autoApply" @update:modelValue="saveAutoApply">Live Updates</HouseSwitch>
            <div class="buttons">
              <HouseButton
                compact
                variant="quiet"
                :icon="icons.undo"
                aria-label="Reset"
                data-fk="reset-tuning"
                v-bng-tooltip="'Hold to reset'"
                v-bng-on-ui-nav:ok.asMouse.focusRequired
                v-bng-click="{ holdCallback: resetTuning, holdDelay: 1000, repeatInterval: 0 }" />
              <HouseButton :disabled="autoApply || !isDirty" :aria-disabled="applying" data-fk="apply-tuning" @click="applyPreview">Apply</HouseButton>
            </div>
          </div>
        </div>
      </div>
      <template #footer></template>
    </ComputerPanel>

    <template v-if="sessionStore.businessData?.showBusinessAccount !== false" #status>
      <BusinessAccountBalance inline />
    </template>

    <template #side>
      <BusinessWorkshopCart
        mode="tuning"
        scope-id="business-tuning-cart"
        :active="isCartActive"
        @return-to-workshop="switchToWorkshop"
        @remove-item="removeCartItem"
        @cancel="confirmExit"
        @purchased="finishPurchase"
      />
    </template>
  </ComputerWrapper>
</template>

<script setup>
import { useActionFocus } from "../composables/useActionFocus.js"
import { reportUiFailure } from "../utils/safeLua"

import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref } from "vue"
import { BngRow, ACCENTS, icons } from "@/common/components/base"
import { vBngBlur, vBngClick, vBngOnUiNav, vBngScopedNav, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, HouseSlider, HouseSwitch, openHouseConfirmation } from "../components/house/index.js"
import { lua } from "@/bridge"
import { useScopedNav } from "@/services/scopedNav/api"
import { useEvents } from "@/services/events"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { useUINavBlocker } from "@/services/uiNavTracker"
import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import BusinessWheelData from "../components/businessComputer/BusinessWheelData.vue"
import BusinessWorkshopCart from "../components/businessComputer/BusinessWorkshopCart.vue"
import BusinessAccountBalance from "../components/businessComputer/BusinessAccountBalance.vue"
import { useBusinessCartStore } from "../stores/businessComputer/businessCartStore.js"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import { useBusinessSessionStore } from "../stores/businessComputer/businessSessionStore.js"
import { useBusinessTuningStore } from "../stores/businessComputer/businessTuningStore.js"

const cartStore = useBusinessCartStore()
const computerStore = useBusinessComputerStore()
const sessionStore = useBusinessSessionStore()
const tuningStore = useBusinessTuningStore()
const events = useEvents()
const { current, switchScope } = useScopedNav()
const navBlocker = useUINavBlocker()
navBlocker.ensureNoBlock(["context"])
const workshopScope = "business-tuning-workshop"
const loading = ref(true)
const actionRoot = ref(null)
const { busy: applying, run } = useActionFocus(actionRoot)
const wheelDataVisible = ref(false)
const autoApply = ref(false)
const variables = reactive({})
const originalData = reactive({})
const buckets = ref([])
let applyTimer = null

const title = computed(() => `${sessionStore.businessName || "Business"} — Tuning`)
const isCartActive = computed(() => current.value?.id === "business-tuning-cart")
const isWorkshopActive = computed(() => current.value?.id === workshopScope)
const switchToCart = () => switchScope("business-tuning-cart")
const switchToWorkshop = () => switchScope(workshopScope)
const tuningBack = () => { confirmExit(); return false }

const bounds = data => {
  const min = Number.isFinite(Number(data.min)) ? Number(data.min) : Number(data.options?.min) || 0
  const max = Number.isFinite(Number(data.max)) ? Number(data.max) : Number(data.options?.max) || 100
  const minDis = Number.isFinite(Number(data.minDis)) ? Number(data.minDis)
    : Number.isFinite(Number(data.options?.minDis)) ? Number(data.options.minDis) : min
  const maxDis = Number.isFinite(Number(data.maxDis)) ? Number(data.maxDis)
    : Number.isFinite(Number(data.options?.maxDis)) ? Number(data.options.maxDis) : max
  const stepDis = Number(data.stepDis ?? data.options?.stepDis ?? data.step)
  return { min, max, minDis, maxDis, stepDis: Number.isFinite(stepDis) && stepDis > 0 ? stepDis : Math.max(0.001, (maxDis - minDis) / 1000) }
}
const toDisplay = (data, actual) => {
  const { min, max, minDis, maxDis } = bounds(data)
  return max !== min && (min !== minDis || max !== maxDis)
    ? ((actual - min) / (max - min)) * (maxDis - minDis) + minDis
    : actual
}
const toActual = data => {
  const { min, max, minDis, maxDis } = bounds(data)
  return maxDis !== minDis && (min !== minDis || max !== maxDis)
    ? ((Number(data.valDis) - minDis) / (maxDis - minDis)) * (max - min) + min
    : Number(data.valDis)
}

const organize = data => {
  const grouped = {}
  for (const [name, raw] of Object.entries(data || {})) {
    if (!raw || typeof raw !== "object") continue
    const range = bounds(raw)
    const actual = Number(raw.val ?? raw.default ?? range.min)
    const item = reactive({
      ...raw,
      ...range,
      name,
      valDis: toDisplay(raw, actual),
      originalDisplay: toDisplay(raw, actual),
    })
    variables[name] = item
    originalData[name] = { ...raw, val: actual, valDis: actual }
    const category = raw.category || "Other"
    const subCategory = raw.subCategory || "Other"
    grouped[category] ||= {}
    grouped[category][subCategory] ||= []
    grouped[category][subCategory].push(item)
  }
  return Object.entries(grouped).sort(([a], [b]) => a.localeCompare(b)).map(([name, children]) => ({
    name,
    items: Object.entries(children).sort(([a], [b]) => a.localeCompare(b)).map(([subName, items]) => ({
      name: subName,
      items: items.sort((a, b) => (a.title || a.name).localeCompare(b.title || b.name)),
    })),
  }))
}

const tuningValues = () => Object.fromEntries(Object.entries(variables).map(([name, data]) => [name, toActual(data)]))
const isDirty = computed(() => Object.entries(variables).some(([name, data]) =>
  Math.abs(toActual(data) - Number(originalData[name]?.val ?? 0)) >= 0.001))

const applyPreview = async () => {
  if (applying.value || !sessionStore.pulledOutVehicle?.vehicleId) return
  return run(async () => {
    const values = tuningValues()
    await tuningStore.addTuningToCart(values, originalData)
    await lua.overhaul_career_business_computer.applyTuningToVehicle(
      sessionStore.businessId,
      sessionStore.pulledOutVehicle.vehicleId,
      values
    )
    tuningStore.updatePowerWeight()
  })
}

const scheduleApply = () => {
  clearTimeout(applyTimer)
  applyTimer = setTimeout(applyPreview, 1000)
}
const onChange = () => { if (autoApply.value) scheduleApply() }
const saveAutoApply = value => localStorage.setItem("applyTuningChangesAutomatically", JSON.stringify(!!value))

const resetTuning = async () => {
  for (const [name, data] of Object.entries(variables)) data.valDis = data.originalDisplay
  await applyPreview()
}

const removeCartItem = async item => {
  const variable = variables[item.varName]
  if (variable) variable.valDis = variable.originalDisplay
  await applyPreview()
}

const onTuningData = data => {
  if (!data || String(data.businessId) !== String(sessionStore.businessId) || String(data.vehicleId) !== String(sessionStore.pulledOutVehicle?.vehicleId)) return
  for (const key of Object.keys(variables)) delete variables[key]
  for (const key of Object.keys(originalData)) delete originalData[key]
  buckets.value = data.success ? organize(data.tuningData) : []
  loading.value = false
}

const requestData = () => {
  loading.value = true
  tuningStore.requestVehicleTuningData(sessionStore.pulledOutVehicle?.vehicleId)
}
const hasChanges = computed(() => (cartStore.tuningCart || []).length > 0 || isDirty.value)
const confirmExit = async () => {
  if (!hasChanges.value || await openHouseConfirmation(null, "Discard unpurchased tuning changes?", [
    { label: "Yes", value: true, extras: { destructive: true } },
    { label: "No", value: false, extras: { accent: ACCENTS.secondary } },
  ])) await computerStore.closeVehicleView()
}
const finishPurchase = () => {
  cartStore.clearCart()
  cartStore.clearCachesForVehicle(sessionStore.pulledOutVehicle?.vehicleId)
  sessionStore.vehicleView = null
}

onMounted(() => {
  events.on("businessComputer:onVehicleTuningData", onTuningData)
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
  try { autoApply.value = !!JSON.parse(localStorage.getItem("applyTuningChangesAutomatically") || "false") } catch (_) { reportUiFailure(_, "optional action (BusinessWorkshopTuning)") }
  requestData()
  nextTick(switchToWorkshop)
})
onBeforeUnmount(() => {
  clearTimeout(applyTimer)
  events.off("businessComputer:onVehicleTuningData", onTuningData)
  getUINavServiceInstance().clearFilteredEvents()
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Same look as the career Tuning screen (Tuning.vue with the house prop): near-black panel, Style
// Guide captions, translucent grouped rows, slim scrollbar, hairline bottom bar. Root is ComputerPanel.
.tuning-card.computer-panel {
  --bng-card-height: 100%;
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(36em, 40%);
  height: 100%;
  max-height: 100%;
  overflow: hidden;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.92);
    font-weight: inherit;
  }
  &:deep(.panel-content) {
    display: flex;
    flex: 1 1 0;
    min-height: 0;
    height: auto;
    overflow: hidden;
    background: transparent;
  }
}
.inner-tuning-card {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow: hidden;
}
.state-message {
  padding: 1.2em 1em;
  color: var(--muted);
  font-weight: 600;
  text-align: center;
}

.tuning-form {
  flex: 1 1 auto;
  min-height: 0;
  padding: 0.35em 0.5em 1em 0.75em;
  overflow-y: auto;
  scrollbar-gutter: stable;
  &::-webkit-scrollbar { width: 0.5em; height: 0.5em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.22);
    border-radius: 1em;
    border: 0.12em solid transparent;
    background-clip: padding-box;
  }
  &::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
}
.tuning-category {
  display: flex;
  flex-direction: column;
  padding: 0.2em 0 0.5em;
}
// Style Guide .caption + hairline rule
.category-heading {
  display: flex;
  align-items: center;
  gap: 0.7em;
  margin: 0;
  padding: 0.9em 0.15em 0.5em;
  color: var(--faint);
  font-size: 0.78em;
  font-style: normal;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  &::after {
    content: "";
    flex: 1 1 auto;
    height: 1px;
    background: var(--line);
  }
}
.tuning-subcategory {
  display: flex;
  flex-direction: column;
}
.subcategory-heading {
  margin: 0;
  padding: 0.7em 0.15em 0.35em;
  color: var(--muted);
  font-size: 0.85em;
  font-style: normal;
  font-weight: 700;
}

// each setting is a translucent line; a subcategory's lines read as one rounded group
.variable-box {
  --bng-bg-enabled: rgba(255, 255, 255, 0.06);
  --bng-bg-hover: rgba(255, 255, 255, 0.1);
  --bng-bg-active: rgba(255, 255, 255, 0.1);
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-border-radius: 0;
  --bng-row-label-padding: 0 0 0.2em;
  --bng-slider-margin: 0.45em;
  --input-width: 6.5em;
  margin: 0;
  padding: 0.6em 0.75em 0.45em;
  border-radius: 0;
  &.focus-visible:not(.no-focus-frame) {
    --bng-bg-enabled: rgba(255, 255, 255, 0.12);
  }
  :deep(.bng-row-background) {
    border-radius: inherit;
  }
  :deep(.bng-row-label) {
    color: #fff;
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.25;
  }
}
.variable-box + .variable-box {
  border-top: 1px solid var(--line);
}
div.variable-box:first-of-type {
  border-top-left-radius: var(--radius-panel);
  border-top-right-radius: var(--radius-panel);
}
div.variable-box:last-of-type {
  border-bottom-left-radius: var(--radius-panel);
  border-bottom-right-radius: var(--radius-panel);
}

.tuning-controls {
  flex: 0 0 auto;
  max-height: calc(100% - 1.5em);
  padding: 0.6em 0.75em;
  border-top: 1px solid var(--line);
  overflow: hidden;
}
.wheel-data {
  max-height: 18em;
  overflow: auto;
}
.controls-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5em 1.2em;
}
.buttons {
  display: flex;
  align-items: center;
  gap: 0.4em;
  margin-left: auto;
}
</style>
