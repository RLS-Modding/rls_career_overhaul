<!-- RLS override of the vanilla career Painting.vue. Script logic, Lua calls, events, scoped nav and the
     paint-slot Tabs state machine are the game's. Chrome is the RLS house look:
     - no inner "Painting" heading (the screen heading already says it)
     - paint slots as a house segmented bar with each slot's live colour swatch, LB/RB arrows kept
     - the finish choice (Factory / Gloss / Metallic / Custom) as a house segmented bar instead of BngSelect
     - PaintPicker / PaintPresets in their `house` mode, house clear coat switch + polish slider
     The cart is rendered by PaintingMain in the ComputerWrapper side column (state exposed as `cart`). -->
<template>
  <div class="painting-wrapper rls-house">
    <ComputerPanel
      class="painting-page"
      tabindex="-1"
      v-bng-blur="1"
      :active="active"
      :class="panelClasses"
      >
      <div class="painting-page-content scroll" v-bng-ui-nav-scroll>
        <div v-if="!hasPaintingData" class="painting-loading">{{ $translate.instant("ui.common.loading") }}</div>
        <template v-else>
          <!-- paint slots: LB / RB (or click) switch the Tabs below; swatch = that slot's current colour -->
          <div class="paint-slots" :style="headerVars">
            <div class="paint-slots-side" bng-no-child-nav="true">
              <HouseButton
                class="paint-slots-arrow"
                compact
                variant="quiet"
                :icon="icons.arrowLargeLeft"
                :nav-item="false"
                :tabindex="-1"
                bng-no-nav="true"
                @click="goPrevTab">
                <BngBinding v-show="active" class="painting-tabs-binding" ui-event="tab_l" controller track-ignore />
              </HouseButton>
            </div>
            <div class="seg bar paint-slot-seg" bng-no-child-nav="true">
              <button
                v-for="(paint, idx) in paints"
                :key="idx"
                type="button"
                tabindex="-1"
                bng-no-nav="true"
                :class="{ active: paintIndex === idx }"
                @click="selectPaintTab(idx)">
                <span class="paint-slot-swatch" :style="{ backgroundColor: `var(--painting-dot-${idx})` }"></span>
                <span class="paint-slot-label">{{ $translate.instant("ui.career.painting.paintTab", { number: idx + 1 }) }}</span>
              </button>
            </div>
            <div class="paint-slots-side" bng-no-child-nav="true">
              <HouseButton
                class="paint-slots-arrow"
                compact
                variant="quiet"
                :icon="icons.arrowLargeRight"
                :nav-item="false"
                :tabindex="-1"
                bng-no-nav="true"
                @click="goNextTab">
                <BngBinding v-show="active" class="painting-tabs-binding" ui-event="tab_r" controller track-ignore />
              </HouseButton>
            </div>
            <span class="painting-tabs-context-slot" bng-no-child-nav="true">
              <BngBinding
                v-show="!active"
                class="painting-tabs-binding"
                ui-event="context"
                controller
                track-ignore
              />
            </span>
          </div>

          <!-- Tabs keeps the vanilla per-slot state machine (change event, goNext / goPrev); its own tab list is replaced by the bar above -->
          <Tabs
            ref="tabsRef"
            class="paint-tabs"
            :selected-index="0"
            :show-tab-list="false"
            @change="changedPaintIndexTab"
          >
            <div
              v-for="(paint, idx) in paints" :key="idx"
              :tab-heading="$translate.instant('ui.career.painting.paintTab', { number: idx + 1 })"
              class="paintClassSelectPane"
            >
              <div class="seg bar paint-class-seg">
                <button
                  v-for="opt in paintClassOptions"
                  :key="opt.id"
                  type="button"
                  :class="{ active: colorClass === opt.id }"
                  bng-nav-item
                  v-bng-sound-class="'bng_click_hover_generic'"
                  @click="pickPaintClass(opt.id)">
                  {{ paintClassSelectConfig.label(opt) }}
                </button>
              </div>
            </div>
          </Tabs>

          <div class="paint-surface">
            <PaintPicker
              ref="paintPicker"
              v-model="paints[paintIndex]"
              :show-main="showPickerMain()"
              :presets="getPickerShowPresets() ? presets : undefined"
              :presets-editable="getPickerPresetsEditable()"
              :advanced-open="false"
              :show-advanced-switch="false"
              house
              @change="onChange" />

            <div v-if="showClearCoatOption()" class="clearCoatSection">
              <HouseSwitch :model-value="clearCoatActive" row @update:model-value="onClearCoatSwitch">
                {{ $translate.instant("ui.career.painting.addClearCoat", { basePrice: units.beamBucks(prices.clearcoatBase.money.amount) }) }}
              </HouseSwitch>
              <div v-if="clearCoatActive" class="clear-coat-polish">
                <div class="clear-coat-polish-head">
                  <span class="caption">{{ $translate.instant("ui.career.painting.clearCoatPolish") }}</span>
                  <span class="clear-coat-polish-value">{{ Math.round(clearCoatPolish * 100) }}%</span>
                </div>
                <HouseSlider v-model="clearCoatPolish" :min="0" :max="1" :step="0.01" @change="changeClearCoatPolish" />
              </div>
            </div>
          </div>
        </template>
      </div>

    </ComputerPanel>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted } from "vue"
import { lua, useBridge } from "@/bridge"
import { Tabs } from "@/common/components/utility"
import { BngCardHeading, BngBinding, icons } from "@/common/components/base"
import { vBngBlur, vBngSoundClass, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, HouseSwitch, HouseSlider } from "../house/index.js"

defineProps({
  active: Boolean,
  showHint: Boolean,
  panelClasses: { type: Object, default: () => ({}) },
})

// Emitted once the initial paintingData payload has arrived and been applied, so
// the route view can ack routeMounted and activate the painting scope.
const emit = defineEmits(["ready"])

import PaintPicker from "../../../vehicleConfig/components/PaintPicker.vue"
import ComputerPanel from "../ComputerPanel.vue"
import Paint from "@/utils/paint"
import { $translate } from "@/services/translation"

const { units, events } = useBridge()

const presets = ref({})

const colorClass = ref("factory")
const paintIndex = ref(0)
const chosenPackage = ref([{}, {}, {}])
const changedPaint = ref(false)
const totalPrice = ref(0)

const clearCoatActive = ref(false)
const clearCoatPolish = ref(0)

const paints = ref([])
const originalPaints = ref([])
const prices = ref({})
const colorClassData = ref({})
const canPay = ref(false)
const paintPicker = ref(null)
const tabsRef = ref(null)


const goPrevTab = () => tabsRef.value?.goPrev?.()
const goNextTab = () => tabsRef.value?.goNext?.()

const hasPaintingData = computed(() => paints.value.length > 0 && !!prices.value.basePrices && !!prices.value.clearcoatBase)

const paintClassTabInfo = [
  {
    defaultPaintClass: "factory",
    titleKey: "ui.color.factory",
  },
  {
    defaultPaintClass: "semiGloss",
    titleKey: "ui.career.painting.tab.gloss",
    paintClasses: [
      { id: "matte", titleKey: "ui.career.painting.class.matte" },
      { id: "semiGloss", titleKey: "ui.career.painting.class.semiGloss" },
      { id: "gloss", titleKey: "ui.career.painting.class.gloss" },
    ],
  },
  {
    defaultPaintClass: "metallic",
    titleKey: "ui.career.painting.tab.metallic",
    paintClasses: [
      { id: "semiMetallic", titleKey: "ui.career.painting.class.semiMetallic" },
      { id: "metallic", titleKey: "ui.color.metallic" },
      { id: "chrome", titleKey: "ui.career.painting.class.chrome" },
    ],
  },
  {
    defaultPaintClass: "custom",
    titleKey: "ui.color.custom",
  },
]

// Expose only the four top-level categories (Factory, Gloss, Metallic, Custom) in
// the paint-class picker. Grouped class entries are not flattened into separate
// visible options; each top-level entry uses its defaultPaintClass.
const paintClassOptions = paintClassTabInfo.map(tab => ({ id: tab.defaultPaintClass, titleKey: tab.titleKey }))

const paintClassSelectConfig = {
  value: opt => opt.id,
  label: opt => $translate.instant(opt.titleKey),
}

const PAINT_CLASS_KEYS = {
  factory: "ui.color.factory",
  custom: "ui.color.custom",
  matte: "ui.career.painting.class.matte",
  semiGloss: "ui.career.painting.class.semiGloss",
  gloss: "ui.career.painting.class.gloss",
  semiMetallic: "ui.career.painting.class.semiMetallic",
  metallic: "ui.color.metallic",
  chrome: "ui.career.painting.class.chrome",
}

// i tried to use a watcher instead of a valueChanged callback, but that broke the painting menu for some reason (it makes the paint picker apply color changes to all 3 vehicle paints)
const clearCoatUpdateCallback = newValue => {
  clearCoatPolish.value = 0
  changeClearCoatPolish(0)
  enableClearCoat(newValue)
}

// house switch: same order as BngSwitch's v-model + valueChanged (model first, then the callback)
const onClearCoatSwitch = newValue => {
  clearCoatActive.value = newValue
  clearCoatUpdateCallback(newValue)
}

// PaintPicker ref can be null when Tabs emits its initial `change` during setup,
// before the nested PaintPicker has mounted. Guard all ref access through these.
const setPaintPickerAdvancedVisible = isVisible => paintPicker.value?.setAdvancedVisible(isVisible)
const notifyPaintPickerUpdated = () => paintPicker.value?.paintUpdated()

const enableClearCoat = enabled => {
  paints.value[paintIndex.value]._clearcoat = enabled ? 1 : 0
  notifyPaintPickerUpdated()
}

const changeClearCoatPolish = value => {
  paints.value[paintIndex.value]._clearcoatRoughness = -0.13 * value + 0.13
  notifyPaintPickerUpdated()
}

// Lua's authoritative cart lines (painting.lua getPriceLines): {paintIndex (1-based), kind, amount}.
// The local fallback below only covers the moment before the first cart update arrives.
const priceLines = ref([])
const linePrice = (index, kind, fallback) => {
  const line = priceLines.value.find(l => l.paintIndex === index + 1 && l.kind === kind)
  return line ? line.amount : Math.round(fallback)
}

const getShoppingCartTable = () => {
  let res = []

  for (const [index, paintOptions] of chosenPackage.value.entries()) {
    if (!Object.keys(paintOptions).length) continue

    res.push({
      name: $translate.instant("ui.career.painting.cart.paintLine", {
        number: index + 1,
        paintClass: getNicePaintClassName(paintOptions.paintClass),
      }),
      price: linePrice(index, "paint", prices.value.basePrices[paintOptions.paintClass].money.amount),
      topLevel: true,
      index,
    })

    if (paintOptions.clearCoat) {
      res.push({
        name: $translate.instant("ui.career.painting.cart.clearcoat"),
        price: linePrice(index, "clearcoat", prices.value.clearcoatBase.money.amount),
      })
      res.push({
        name: $translate.instant("ui.career.painting.cart.extraClearCoatPolish"),
        price: linePrice(index, "polish", prices.value.clearcoatPolishFactor.money.amount * paintOptions.clearCoatPolish),
      })
    }
  }

  return res
}

const setPaintingShoppingCartData = data => {
  canPay.value = data.canPay
  totalPrice.value = data.totalPrice.money.amount
  priceLines.value = Array.isArray(data.priceLines) ? data.priceLines : []
}

const setPaintingData = data => {
  if (!data) return
  presets.value = data.factoryPaint || {}
  prices.value = data.prices || {}
  colorClassData.value = data.colorClassData || {}
  if (!Array.isArray(data.colors)) {
    paints.value = []
    originalPaints.value = []
    return
  }
  paints.value = data.colors.map(val => new Paint({ paint: val }))
  originalPaints.value = data.colors.map(val => new Paint({ paint: val }))
  if (hasPaintingData.value) emit("ready")
}

const getPickerShowPresets = () => colorClass.value == "factory"

const getPickerPresetsEditable = () => colorClass.value == "custom"

const showPickerMain = () => colorClass.value != "factory"

const showClearCoatOption = () => colorClass.value != "factory" && colorClass.value != "custom"

// Picking a finish tab (Gloss / Metallic / ...) only changes which picker is shown. The finish is
// applied with the player's first real edit in onChange; applying it here pinged the picker, which
// emits `change`, so just opening the Metallic tab put a paint job in the cart and repainted the car.
const pendingFinish = ref(null) // { index, paintClass }

const setCurrentColorClass = () => {
  setPaintPickerAdvancedVisible(false)
  clearCoatActive.value = false
  pendingFinish.value = { index: paintIndex.value, paintClass: colorClass.value }
}

// apply a pending finish to the edited paint; true when it did (the picker is then re-synced and
// re-emits `change`, which runs onChange again with the finished paint)
const applyPendingFinish = () => {
  const pending = pendingFinish.value
  if (!pending || pending.index !== paintIndex.value || pending.paintClass !== colorClass.value) return false
  pendingFinish.value = null
  const finish = colorClassData.value[pending.paintClass]
  if (!finish) return false
  const paint = paints.value[paintIndex.value]
  paint._metallic = finish.metallic
  paint._roughness = finish.roughness
  if (!clearCoatActive.value) paint._clearcoat = 0
  notifyPaintPickerUpdated()
  return true
}

const changedPaintIndexTab = tab => {
  pendingFinish.value = null
  paintIndex.value = tab.index
  colorClass.value = chosenPackage.value[paintIndex.value].paintClass || "factory"
  setPaintPickerAdvancedVisible(colorClass.value == "custom")
  clearCoatActive.value = !!chosenPackage.value[paintIndex.value].clearCoat
  clearCoatPolish.value = chosenPackage.value[paintIndex.value].clearCoatPolish || 0
}

const changedPaintClassSelect = paintClass => changedPaintClassTab(paintClass)

// house segmented bar: same as the BngSelect's v-model + change (picking the current one is a no-op, as in the select)
const pickPaintClass = paintClass => {
  if (colorClass.value === paintClass) return
  colorClass.value = paintClass
  changedPaintClassSelect(paintClass)
}

// house paint-slot bar: clicking a slot selects that tab (Tabs emits `change` like its own tab list did)
const selectPaintTab = index => tabsRef.value?.selectTab?.(index)

const changedPaintClassTab = paintClass => {
  pendingFinish.value = null
  if (paintClass == "factory") {
    colorClass.value = "factory"
    return
  }
  if (paintClass == "custom") {
    colorClass.value = "custom"
    setPaintPickerAdvancedVisible(true)
    clearCoatActive.value = false
    return
  }

  colorClass.value = paintClass
  setCurrentColorClass()
}

function resetPaint(index) {
  chosenPackage.value[index] = {}

  // Copy the original paint
  Object.assign(paints.value[index], originalPaints.value[index])

  let chosenPackageEmpty = true
  for (const color of Object.values(chosenPackage.value)) {
    if (Object.keys(color).length !== 0) {
      chosenPackageEmpty = false
    }
  }
  if (chosenPackageEmpty) {
    changedPaint.value = false
  }

  lua.overhaul_career_parts_painting.setPaints(
    paints.value.map(paint => paint.paintObject),
    chosenPackage.value
  )

}

function onChange() {
  if (applyPendingFinish()) return
  if (colorClass.value == "factory") {
    clearCoatActive.value = false
  }
  chosenPackage.value[paintIndex.value].paintClass = colorClass.value
  chosenPackage.value[paintIndex.value].clearCoat = clearCoatActive.value
  chosenPackage.value[paintIndex.value].clearCoatPolish = clearCoatPolish.value

  changedPaint.value = true

  lua.overhaul_career_parts_painting.setPaints(
    paints.value.map(paint => paint.paintObject),
    chosenPackage.value
  )
}

const getNicePaintClassName = paintClass => {
  const key = PAINT_CLASS_KEYS[paintClass]
  return key ? $translate.instant(key) : paintClass
}

const headerVars = computed(() =>
  paints.value.reduce(
    (res, paint, idx) => ({
      ...res,
      [`--painting-dot-${idx}`]: `hsl(${Paint.hslCssStr(paint.hsl)})`,
    }),
    {}
  )
)

const apply = () => lua.overhaul_career_parts_painting.apply()
const close = () => lua.overhaul_career_parts_painting.close()

// Cart state for PaintShoppingCart (rendered by PaintingMain in the side column). Same props the
// vanilla template passed to the cart it rendered here.
const cart = computed(() => ({
  changedPaint: changedPaint.value,
  rows: getShoppingCartTable(),
  totalPrice: totalPrice.value,
  canPay: canPay.value,
}))

const start = () => {
  events.on("paintingData", setPaintingData)
  events.on("sendPaintingShoppingCartData", setPaintingShoppingCartData)
  lua.overhaul_career_parts_painting.onUIOpened()
  lua.overhaul_career_parts_painting.sendPaintingDataToUI()
}

onMounted(start)
onUnmounted(() => {
  events.off("paintingData", setPaintingData)
  events.off("sendPaintingShoppingCartData", setPaintingShoppingCartData)
  lua.overhaul_career_parts_painting.cleanup()
})

defineExpose({
  apply,
  close,
  cart,
  resetPaint,
  goPrevTab,
  goNextTab,
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.painting-wrapper.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  position: relative;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}

// Root is ComputerPanel: `.painting-page.computer-panel` outranks its scoped surface rules.
// Top-left under the screen heading; height follows the content up to the screen.
.painting-page.computer-panel {
  --bng-card-height: auto;
  font-size: inherit;
  width: 36em;
  max-width: 100%;
  max-height: 100%;
  min-height: 0;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);

  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.82);
    font-weight: inherit;
  }

  > :deep(.panel-content) {
    flex: 1 1 auto;
    min-height: 0;
    background: transparent;
  }
}

.painting-page-content {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
  min-height: 0;
  padding: var(--inset);
  overflow-y: auto;
}

.painting-loading {
  padding: 0.5em 0.15em;
  color: var(--muted);
  font-weight: 600;
}

// ---- paint slots bar
.paint-slots {
  display: flex;
  align-items: center;
  gap: 0.35em;
}

.paint-slots-side {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
}

.paint-slots-arrow {
  min-width: 2.6em;
  :deep(.btn-label) {
    display: inline-flex;
    align-items: center;
  }
  :deep(.btn-label:empty) {
    display: none;
  }
}

.paint-slot-seg {
  flex: 1 1 auto;
  min-width: 0;
  button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 0.5em;
    min-width: 0;
  }
}

// the slot's current paint (content, not a status dot): a small square swatch
.paint-slot-swatch {
  flex: 0 0 auto;
  width: 0.95em;
  height: 0.95em;
  border-radius: 0.2em;
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.25);
  transform: translateY(-0.06em);
}

.paint-slot-label {
  padding-top: 0.08em;
  white-space: nowrap;
}

.painting-tabs-binding {
  pointer-events: none;
}

.painting-tabs-context-slot {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 2em;
  height: 2em;
}

// ---- finish (paint class)
.paint-tabs {
  flex: 0 0 auto;
  :deep(.tab-content) {
    overflow: visible;
  }
}

.paint-class-seg button {
  padding-top: 0.5em;
  padding-bottom: 0.36em;
}

// ---- picker / presets surface
.paint-surface {
  display: grid;
  gap: 1em;
  padding: var(--inset);
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.clearCoatSection {
  display: grid;
  gap: 0.8em;
  padding-top: 0.9em;
  border-top: 1px solid var(--line);
}

.clear-coat-polish {
  display: grid;
  gap: 0.25em;
}

.clear-coat-polish-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
}

.clear-coat-polish-value {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
</style>
