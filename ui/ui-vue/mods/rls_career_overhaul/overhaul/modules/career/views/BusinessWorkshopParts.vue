<template>
  <ComputerWrapper :title="title" @back="goBack">
    <ComputerPanel
      v-bng-scoped-nav="{ scopeId: workshopScope, trapPolicy: 'always', canDeactivate: onPartsBack }"
      v-bng-blur="1"
      v-bng-on-ui-nav:context="switchToCart"
      class="parts-panel rls-house"
      :active="isWorkshopActive"
    >
      <template #heading>
        <PartNavigation :label="heading" :can-back="!loading && panel !== 'categories'" :active="isWorkshopActive" @back="goBack" />
      </template>
      <div v-if="loading" class="state-message">Loading parts…</div>

      <div v-else-if="panel === 'categories'" class="category-list">
        <Button bng-scoped-nav-autofocus class="computer-function-tile" @click="openCategory('everything')">
          <BngIcon class="category-icon" :type="icons.doorFrontCoins" />
          <span class="label">All Parts</span>
        </Button>
        <Button class="computer-function-tile" @click="openCategory('cargo')">
          <BngIcon class="category-icon" :type="icons.boxPickUp03" />
          <span class="label">Cargo Parts</span>
        </Button>
      </div>

      <div v-else-if="panel === 'slots'" class="slot-list-root">
        <div class="search-container">
          <BngInput v-model="slotSearch" :leading-icon="icons.search" label="Search" floating-label />
        </div>
        <div class="slot-list" :class="{ 'search-results': slotSearch.trim() }" v-bng-ui-nav-scroll>
          <Accordion v-if="slotSearch.trim()">
            <AccordionItem
              v-for="slot in filteredSlots"
              :key="slot.path"
              v-bng-tooltip:right="slotPathTooltip(slot.nicePath)"
              static
              navigable
              :primary-action="() => openSlot(slot)"
              @selected="openSlot(slot)"
            >
              <template #caption>
                <span class="slot-path">{{ compactSlotPath(slot.nicePath) }}</span>
                <span class="slot-name">{{ slot.slotNiceName }}</span>
              </template>
              <template #controls>
                <HouseButton bng-no-nav="true" class="selected-part" compact @click="openSlot(slot)">
                  {{ slot.partNiceName || "-" }}
                </HouseButton>
              </template>
            </AccordionItem>
          </Accordion>
          <BusinessPartsSlotTree
            v-else
            :children="partTree.children"
            :expanded-slots="expandedSlots"
            @open-slot="openTreeSlot"
            @set-expanded="setSlotExpanded"
          />
        </div>
      </div>

      <div v-else class="parts-wrapper">
        <div class="search-container">
          <BngInput v-model="partSearch" :leading-icon="icons.search" label="Search" floating-label />
        </div>
        <div v-if="displayedParts.length" class="parts-list" v-bng-ui-nav-scroll>
          <div v-for="part in displayedParts" :key="part.key" class="part-item" :class="{ installed: part.installed }">
            <div class="part-info">
              <span class="part-name">{{ part.label }}</span>
              <div class="part-meta">
                <span v-if="part.inventory" class="pill">Business inventory</span>
                <span v-if="part.mileage != null" class="mileage">{{ formatMileage(part.mileage) }}</span>
                <span v-if="!part.inventory && !part.remove" class="price">{{ units.beamBucks(part.price) }}</span>
              </div>
            </div>
            <HouseButton
              class="part-action"
              :class="{ 'is-undo': part.cartItem }"
              compact
              :variant="part.cartItem ? 'quiet-danger' : part.installed ? 'quiet' : 'neutral'"
              :disabled="busy || (part.installed && !part.cartItem)"
              :icon="part.cartItem ? icons.undo : ''"
              @click="activatePart(part)"
            >
              <span v-if="!part.cartItem">{{ part.remove ? "Remove" : part.installed ? "Installed" : "Install" }}</span>
            </HouseButton>
          </div>
        </div>
        <div v-else class="state-message">No matching parts.</div>
      </div>
    </ComputerPanel>

    <template v-if="sessionStore.businessData?.showBusinessAccount !== false" #status>
      <BusinessAccountBalance inline />
    </template>

    <template #side>
      <BusinessWorkshopCart
        mode="parts"
        scope-id="business-parts-cart"
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
import Accordion from "../components/PartsAccordion.vue"
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { BngIcon, BngInput, ACCENTS, icons } from "@/common/components/base"
import { HouseButton, openHouseConfirmation } from "../components/house/index.js"
import { AccordionItem, Button } from "@/common/components/utility"
import { vBngBlur, vBngOnUiNav, vBngScopedNav, vBngTooltip, vBngUiNavScroll } from "@/common/directives"
import { compactSlotPath, slotPathTooltip } from "../utils/partSlotBreadcrumb.js"
import { useBridge } from "@/bridge"
import { useScopedNav } from "@/services/scopedNav/api"
import { useEvents } from "@/services/events"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { useUINavBlocker } from "@/services/uiNavTracker"
import ComputerWrapper from "./ComputerWrapper.vue"
import ComputerPanel from "../components/ComputerPanel.vue"
import PartNavigation from "../components/partShopping/PartNavigation.vue"
import BusinessPartsSlotTree from "../components/businessComputer/BusinessPartsSlotTree.vue"
import BusinessWorkshopCart from "../components/businessComputer/BusinessWorkshopCart.vue"
import BusinessAccountBalance from "../components/businessComputer/BusinessAccountBalance.vue"
import { useBusinessCartStore } from "../stores/businessComputer/businessCartStore.js"
import { useBusinessComputerStore } from "../stores/businessComputerStore"
import { useBusinessPartsStore } from "../stores/businessComputer/businessPartsStore.js"
import { useBusinessSessionStore } from "../stores/businessComputer/businessSessionStore.js"
import { formatOdometer, METERS_PER_MILE } from "../utils/units"

const cartStore = useBusinessCartStore()
const computerStore = useBusinessComputerStore()
const partsStore = useBusinessPartsStore()
const sessionStore = useBusinessSessionStore()
const events = useEvents()
const { units } = useBridge()
const { current, switchScope } = useScopedNav()
const navBlocker = useUINavBlocker()
navBlocker.ensureNoBlock(["context"])
const workshopScope = "business-parts-workshop"
const panel = ref("categories")
const category = ref("everything")
const selectedSlot = ref(null)
const slots = ref([])
const partTree = ref({ children: [] })
const slotNames = ref({})
const loading = ref(true)
const busy = ref(false)
const slotSearch = ref("")
const partSearch = ref("")
const expandedSlots = ref({})

const title = computed(() => `${sessionStore.businessName || "Business"} — Parts`)
const heading = computed(() => {
  if (panel.value === "categories") return "Categories"
  if (panel.value === "slots") return "All Parts"
  return selectedSlot.value?.slotNiceName || (category.value === "cargo" ? "Cargo Parts" : "Parts")
})
const isCartActive = computed(() => current.value?.id === "business-parts-cart")
const isWorkshopActive = computed(() => current.value?.id === workshopScope)
const switchToCart = () => switchScope("business-parts-cart")
const switchToWorkshop = () => switchScope(workshopScope)
watch(panel, () => nextTick(switchToWorkshop))

const nicePath = slot => {
  let path = "/"
  return slot.path.split("/").filter(Boolean).map(segment => {
    path += segment + "/"
    return slotNames.value[path] || slotNames.value[segment] || segment
  }).join(" > ")
}
const filteredSlots = computed(() => {
  const query = slotSearch.value.trim().toLowerCase()
  return slots.value
    .map(slot => ({ ...slot, nicePath: nicePath(slot) }))
    .filter(slot => !query || `${slot.slotNiceName} ${slot.nicePath} ${slot.partNiceName}`.toLowerCase().includes(query))
    .sort((a, b) => (a.slotNiceName || "").localeCompare(b.slotNiceName || ""))
})

const setSlotExpanded = (path, expanded) => {
  expandedSlots.value[path] = expanded
}

// metres for display: Lua's variant.mileage is miles (odometer / 1609.344), the part odometer is metres
const normalizeMileage = variant => {
  if (Number.isFinite(Number(variant.mileage))) return Number(variant.mileage) * METERS_PER_MILE
  const odometer = Number(variant.partCondition?.odometer)
  return Number.isFinite(odometer) ? odometer : null
}
const cartForPart = (slot, partName, partId) => (cartStore.partsCart || []).find(item =>
  item.slotPath === slot.path && item.partName === partName && (partId == null || String(item.partId) === String(partId)))

const partsForSlot = slot => {
  if (!slot) return []
  const result = []
  if (slot.canRemove) {
    const removal = (cartStore.partsCart || []).find(item => item.slotPath === slot.path && item.emptyPlaceholder)
    result.push({ key: `remove-${slot.path}`, label: "Remove current part", remove: true, canRemove: true, cartItem: removal })
  }
  for (const part of slot.availableParts || []) {
    const newCartItem = cartForPart(slot, part.name, null)
    result.push({
      key: `new-${slot.path}-${part.name}`,
      label: part.niceName || part.name,
      name: part.name,
      price: Number(part.value) || 0,
      installed: !!part.installed,
      canRemove: !!slot.canRemove,
      cartItem: newCartItem?.fromInventory ? null : newCartItem,
      source: part,
      slot,
    })
    for (const variant of part.ownedVariants || []) {
      result.push({
        key: `inventory-${slot.path}-${variant.partId}`,
        label: part.niceName || part.name,
        name: part.name,
        partId: variant.partId,
        price: 0,
        inventory: true,
        mileage: normalizeMileage(variant),
        installed: !!cartForPart(slot, part.name, variant.partId),
        cartItem: cartForPart(slot, part.name, variant.partId),
        source: { ...part, ...variant, name: part.name, value: 0, fromInventory: true },
        slot,
      })
    }
  }
  return result
}

const allCargoParts = computed(() => slots.value.flatMap(slot =>
  partsForSlot(slot).filter(part => part.name?.includes("cargo_load"))))
const displayedParts = computed(() => {
  const source = category.value === "cargo" ? allCargoParts.value : partsForSlot(selectedSlot.value)
  const query = partSearch.value.trim().toLowerCase()
  return source.filter(part => !query || part.label.toLowerCase().includes(query))
})

const openCategory = value => {
  category.value = value
  selectedSlot.value = null
  panel.value = value === "cargo" ? "parts" : "slots"
}
const openSlot = slot => {
  selectedSlot.value = slot
  category.value = "everything"
  partSearch.value = ""
  panel.value = "parts"
}
const openTreeSlot = path => {
  const slot = slots.value.find(candidate => candidate.path === path)
  if (slot) openSlot(slot)
}

const loadTree = () => {
  loading.value = true
  partsStore.requestVehiclePartsTree(sessionStore.pulledOutVehicle?.vehicleId)
}
const onTreeData = data => {
  if (!data || String(data.businessId) !== String(sessionStore.businessId) || String(data.vehicleId) !== String(sessionStore.pulledOutVehicle?.vehicleId)) return
  slots.value = data.success && Array.isArray(data.partsTree) ? data.partsTree : []
  partTree.value = data.success && data.partTreeHierarchy ? data.partTreeHierarchy : { children: [] }
  slotNames.value = data.slotsNiceName || {}
  if (selectedSlot.value) selectedSlot.value = slots.value.find(slot => slot.path === selectedSlot.value.path) || null
  loading.value = false
}

const activatePart = async part => {
  if (busy.value) return
  busy.value = true
  try {
    if (part.cartItem) {
      await partsStore.removePartFromCart(part.cartItem.id)
    } else if (part.remove) {
      await partsStore.removePartBySlotPath(selectedSlot.value?.path || part.slot?.path)
    } else if (!part.installed) {
      await partsStore.addPartToCart(part.source, part.slot)
    }
  } finally {
    busy.value = false
  }
}

const removeCartItem = item => item.itemId ? partsStore.removePartFromCart(item.itemId) : partsStore.removePartBySlotPath(item.slotPath)
const hasChanges = computed(() => (cartStore.partsCart || []).length > 0)
const exit = () => computerStore.closeVehicleView()
const confirmExit = async () => {
  if (!hasChanges.value || await openHouseConfirmation(null, "Discard unpurchased part changes?", [
    { label: "Yes", value: true },
    { label: "No", value: false, extras: { accent: ACCENTS.secondary } },
  ])) await exit()
}
const goBack = () => {
  const search = panel.value === "slots" ? slotSearch : panel.value === "parts" ? partSearch : null
  if (search?.value) {
    search.value = ""
    return
  }
  if (panel.value === "parts" && category.value !== "cargo") panel.value = "slots"
  else if (panel.value !== "categories") panel.value = "categories"
  else confirmExit()
}
const onPartsBack = event => {
  event?.stopPropagation()
  goBack()
  return false
}
const finishPurchase = () => {
  cartStore.clearCart()
  cartStore.clearCachesForVehicle(sessionStore.pulledOutVehicle?.vehicleId)
  sessionStore.vehicleView = null
}
const formatMileage = metres => formatOdometer(units, metres)

onMounted(() => {
  events.on("businessComputer:onVehiclePartsTree", onTreeData)
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
  loadTree()
  nextTick(switchToWorkshop)
})
onBeforeUnmount(() => {
  events.off("businessComputer:onVehiclePartsTree", onTreeData)
  getUINavServiceInstance().clearFilteredEvents()
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

// Same look as the career Part Shop (PartShoppingMain + Categories / SlotItem / PartsList).
// Root is ComputerPanel: `.parts-panel.computer-panel` outranks its scoped surface rules.
.parts-panel.computer-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(30em, 40%);
  height: 100%;
  color: #fff;
  background-color: rgba(21, 21, 23, 0.92);
  border-bottom: 0;
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  &.panel-inactive-controller {
    background-color: rgba(21, 21, 23, 0.92);
    font-weight: inherit;
    :deep(.heading::before) {
      background: rgba(255, 255, 255, 0.3);
    }
  }
  &:deep(.panel-content) {
    flex: 1 1 0;
    min-height: 0;
    background: transparent;
  }
}
.state-message {
  padding: 1.2em 1em;
  color: var(--muted);
  font-weight: 600;
  text-align: center;
}

/* ---- categories: house tiles, plain glyph */
.category-list {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
  padding: 0.35em var(--inset) var(--inset);
}
.computer-function-tile {
  --bng-content-flow: row;
  --bng-content-align: center;
  --bng-content-justify: flex-start;
  --bng-button-min-width: 100%;
  --bng-button-max-width: 100%;
  --bng-button-margin: 0;
  --bng-button-padding: 0.6em 0.75em;
  --bng-button-padding-top: 0.6em;
  --bng-button-padding-bottom: 0.6em;
  --bng-bg-border-radius: var(--radius-panel);
  --bng-bg-border-width: 0;
  --bng-bg-enabled: var(--panel);
  --bng-bg-hover: var(--panel-2);
  --bng-bg-active: var(--panel-hover);
  --bng-bg-focus: var(--panel-2);
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-focus-opacity: 1;
  --bng-bg-border-enabled: transparent;
  --bng-bg-border-hover: transparent;
  --bng-bg-border-active: transparent;
  --bng-bg-border-focus: transparent;
  --bng-icon-color: currentColor;
  gap: 0.75em;
  font-family: "Overpass", var(--fnt-defs);
  @include modify-focus(var(--radius-panel, 0.5em), 0.25rem);
  .category-icon {
    flex: 0 0 auto;
    width: 1.3em;
    font-size: 1.4em;
    text-align: center;
    color: var(--faint);
    transition: color 120ms ease;
  }
  &:hover .category-icon,
  &:focus .category-icon {
    color: #fff;
  }
  .label {
    flex: 1 1 auto;
    font-size: 1.15em;
    font-weight: 700;
    line-height: 1.2;
    text-align: left;
  }
}

/* ---- slot list and parts list */
.slot-list-root,
.parts-wrapper {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  height: 100%;
  overflow: hidden;
}
// house search field on the vanilla BngInput
.search-container {
  flex: 0 0 auto;
  padding: 0.35em var(--inset) 0.5em;
  :deep(.bng-input) {
    border-radius: var(--radius-panel);
    background: rgba(0, 0, 0, 0.3);
    box-shadow: inset 0 0 0 1px var(--line);
  }
  :deep(.bng-input:has(input:focus)) {
    box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6);
  }
  :deep(.bng-input .input-container) {
    background: transparent;
  }
  :deep(.bng-input .input-container::before) {
    display: none;
  }
  :deep(.bng-input .leading-icon) {
    padding-left: 0.5em;
    color: var(--faint);
    --bng-icon-color: currentColor;
  }
  :deep(.bng-input label) {
    color: var(--faint);
  }
}
.slot-list,
.parts-list {
  flex: 1 1 auto;
  min-height: 0;
  padding: 0 0.35em 0.5em var(--inset);
  overflow: hidden auto;
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
.slot-path,
.slot-name {
  display: block;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.search-results {
  min-width: 0;
  :deep(.bng-accitem-caption) {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 45%);
    gap: 0.35em;
  }
  :deep(.bng-accitem-caption-content),
  :deep(.bng-accitem-caption-controls) {
    min-width: 0;
  }
  .selected-part {
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
    max-width: 100% !important;
    margin-left: 0;
  }
}
.slot-name {
  font-weight: 600;
  white-space: normal;
  overflow-wrap: anywhere;
}
.slot-path {
  color: var(--faint);
  font-size: 0.7em;
  line-height: 1.25;
}
.selected-part {
  max-width: 13em !important;
  white-space: normal;
  overflow-wrap: anywhere;
  text-align: right;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
}

.part-item {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  min-height: 4em;
  padding: 0.45em 0.5em 0.4em 0.6em;
  border-bottom: 1px solid var(--line);
  color: #fff;
  &:last-child {
    border-bottom-color: transparent;
  }
  // installed part: slightly brighter panel + accent-soft name, no orange gradient
  &.installed {
    border-radius: var(--radius-panel);
    border-bottom-color: transparent;
    background: var(--panel-2);
    .part-name {
      color: var(--accent-soft);
    }
  }
}
.part-info {
  display: grid;
  gap: 0.25em;
  flex: 1 1 auto;
  min-width: 0;
}
.part-name {
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.part-meta {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.3em 0.75em;
  color: var(--muted);
  font-size: 0.9em;
  font-weight: 600;
  .mileage {
    color: var(--faint);
  }
  .price {
    margin-left: auto;
    color: var(--money);
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
}
.part-action {
  flex: 0 0 auto;
  min-width: 6.25em;
  &.is-undo :deep(.btn-label) {
    display: none;
  }
}
</style>
