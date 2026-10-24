<template>
  <div class="parts-wrapper">
    <div class="search-container">
      <BngInput
        v-model="searchTerm"
        :leading-icon="icons.search"
        :label="$translate.instant('ui.common.search')"
        floating-label
      />
    </div>

    <div
      v-if="displayedParts.length > 0"
      ref="partsListEl"
      class="parts-list"
      v-bng-ui-nav-scroll
      @scroll="onPartsListScroll"
      @focusin="onPartsFocus"
    >
      <div
        v-for="part in displayedParts"
        :key="partKey(part)"
        :data-part-key="partKey(part)"
        class="part-item"
        :class="{ 'part-installed': isInstalled(part), 'part-owned': !!part.partId, 'disabled': part.disabled }"
      >
        <div class="part-info-col">
          <div>
            <span class="part-name">
              <div v-if="part.partId">
                {{ part.description.description }}
              </div>
              <div v-else-if="part.emptyPlaceholder">
                {{ $translate.instant("ui.career.partShopping.removeCurrentPart") }}
              </div>
              <div v-else>
                {{ part.description.description }}
              </div>
            </span>
          </div>
          <div class="part-info-row">
            <!-- what is on the car now, and parts the player already owns (free to fit) -->
            <span v-if="isInstalled(part)" class="part-chip chip-installed">
              <BngIcon :type="icons.checkmark" />Installed
            </span>
            <span v-if="part.partId" class="part-chip chip-owned">
              <BngIcon :type="icons.cardboardBox" />{{ $translate.instant("ui.career.partShopping.inventory") }}
            </span>
            <span v-if="part.partId" class="mileage-text">
              {{ $translate.instant("ui.career.shared.mileagePrefix") }}{{ units.buildString("length", part.partCondition.odometer, 0) }}
            </span>
            <span v-if="partShoppingStore.category === 'cargo'">
              {{ partShoppingStore.partShoppingData?.slotsNiceName?.[part.containingSlot] }}
            </span>
            <span v-if="part.disabled && part.disabledReason" class="disabled-reason">{{ part.disabledReason }}</span>
            <span v-if="!part.partId && !part.emptyPlaceholder" class="right"><BngPropVal :iconType="icons.beamCurrency" :valueLabel="units.beamBucks(part.finalValue)" /></span>
          </div>
        </div>

        <HouseButton
          :variant="getCorrespondingPartInShoppingCart(part) ? 'quiet-danger' : 'neutral'"
          compact
          class="part-button"
          :class="{ 'is-undo': getCorrespondingPartInShoppingCart(part) }"
          :bng-scoped-nav-autofocus="partShoppingStore.activePanel === 'parts' && partKey(part) === entryPartKey ? true : undefined"
          :disabled="partShoppingStore.partShoppingData?.restoreInProgress || part.disabled || tutorialBlocksPart(part) || isPartInShoppingCartButNotRemovable(part)"
          @click="isPartRemovableFromShoppingCart(part) ? lua.overhaul_career_parts_partShopping.removePartBySlot(part.containingSlot) : lua.overhaul_career_parts_partShopping.installPartByPartShopId(part.partShopId)"
          :icon="getCorrespondingPartInShoppingCart(part) ? icons.undo : ''">
          <div v-if="!getCorrespondingPartInShoppingCart(part)">
            {{ part.emptyPlaceholder ? $translate.instant("ui.career.partShopping.remove") : $translate.instant("ui.career.partShopping.install") }}
          </div>
        </HouseButton>
      </div>
    </div>
    <div v-else-if="searchTerm && (partShoppingStore.filteredParts?.length > 0)" class="no-results">
      No parts matching "{{ searchTerm }}"
    </div>
  </div>
</template>

<script setup>
import { BngPropVal, BngInput, BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../house/index.js"
import { vBngUiNavScroll } from "@/common/directives"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"
import { lua, useBridge } from "@/bridge"
import { ref, computed, watch, nextTick } from "vue"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()

// the part on the car right now (by jbeam name), so the shop copy of it is flagged "Installed";
// inventory copies and the remove placeholder are never the installed one
const isInstalled = part => {
  if (!part || part.partId || part.emptyPlaceholder) return false
  const installed = partShoppingStore.partShoppingData?.vehicleSlotToPartMap?.[part.containingSlot]
  return !!installed && installed.name === part.name
}

const { units } = useBridge()
const searchTerm = ref("")
const clearSearch = () => {
  if (!searchTerm.value) return false
  searchTerm.value = ""
  return true
}
defineExpose({ clearSearch })
const partsListEl = ref(null)
let savedScrollTop = 0
let restoringScroll = false

const displayedParts = computed(() => {
  const parts = partShoppingStore.filteredParts || []
  if (!searchTerm.value) return parts

  const term = searchTerm.value.toLowerCase()
  return parts.filter(part =>
    part.description?.description?.toLowerCase?.().includes(term)
  )
})

const partKey = (part) => {
  if (part.partShopId != null) return `shop-${part.partShopId}`
  if (part.partId != null) return `inv-${part.partId}`
  if (part.emptyPlaceholder) return `empty-${part.containingSlot || "slot"}`
  return `${part.containingSlot || "slot"}-${part.name || "part"}`
}

const onPartsListScroll = () => {
  // Ignore the transient scrollTop=0 that Vue emits while the list re-renders after install.
  if (restoringScroll || !partsListEl.value) return
  savedScrollTop = partsListEl.value.scrollTop
}

// Opening a different slot should start at the top; returning to the same slot keeps scroll.
watch(
  () => partShoppingStore.slot,
  (next, prev) => {
    if (next && next !== prev) {
      savedScrollTop = 0
      if (partsListEl.value) partsListEl.value.scrollTop = 0
    }
  }
)

// Install/remove refreshes filteredParts and would otherwise snap the list to top.
watch(
  () => partShoppingStore.filteredParts,
  () => {
    if (partsListEl.value && !restoringScroll) {
      savedScrollTop = partsListEl.value.scrollTop
    }
    restoringScroll = true
    nextTick(() => {
      requestAnimationFrame(() => {
        if (partsListEl.value) {
          partsListEl.value.scrollTop = savedScrollTop
        }
        restoringScroll = false
      })
    })
  },
  { flush: "pre" }
)

// Controller: opening a slot lands on its first usable part (not the back button / search box), and
// an install / remove that disables the focused button keeps a pad on that row or the next usable one.
const partDisabled = part =>
  !!(partShoppingStore.partShoppingData?.restoreInProgress || part.disabled || tutorialBlocksPart(part) || isPartInShoppingCartButNotRemovable(part))
const entryPartKey = computed(() => {
  const first = displayedParts.value.find(part => !partDisabled(part))
  return first ? partKey(first) : null
})
let focusedPartKey = null
const onPartsFocus = event => {
  focusedPartKey = event.target?.closest?.("[data-part-key]")?.dataset.partKey || focusedPartKey
}
// note the focused row before the list re-renders (focus events are not delivered while the window
// is unfocused, so @focusin alone can miss it)
watch(
  () => partShoppingStore.filteredParts,
  () => onPartsFocus({ target: document.activeElement }),
  { flush: "pre" }
)
watch(
  () => partShoppingStore.filteredParts,
  () => {
    if (!focusedPartKey) return
    refocusIfLost(() => {
      const rows = [...(partsListEl.value?.querySelectorAll("[data-part-key]") || [])]
      const at = Math.max(0, rows.findIndex(row => row.dataset.partKey === focusedPartKey))
      for (const row of [...rows.slice(at), ...rows.slice(0, at).reverse()]) {
        const btn = row.querySelector("button:not([disabled])")
        if (btn) return btn
      }
      return null
    })
  },
  { flush: "post" }
)

const getCorrespondingPartInShoppingCart = (part) => {
  if (!partShoppingStore.partShoppingData || !partShoppingStore.partShoppingData.shoppingCart) return false
  let partList = partShoppingStore.partShoppingData.shoppingCart.partsInList
  for (let i = 0; i < partList.length; i++) {
    let shoppingCartPart = partList[i]
    if (shoppingCartPart.partId == part.partId && part.name == shoppingCartPart.name && part.containingSlot == shoppingCartPart.containingSlot) return shoppingCartPart
  }
  return false
}

const isShoppingCartPartSourcePart = (part) => {
  return part.sourcePart
}

const isPartRemovableFromShoppingCart = (part) => {
  let shoppingCartPart = getCorrespondingPartInShoppingCart(part)
  return shoppingCartPart && isShoppingCartPartSourcePart(shoppingCartPart)
}

const isPartInShoppingCartButNotRemovable = (part) => {
  let shoppingCartPart = getCorrespondingPartInShoppingCart(part)
  return shoppingCartPart && !isShoppingCartPartSourcePart(shoppingCartPart)
}

const tutorialBlocksPart = (part) => {
  const tutorialPartNames = partShoppingStore.partShoppingData?.tutorialPartNames
  if (tutorialPartNames === undefined) return false
  return !tutorialPartNames[part.name] || isPartRemovableFromShoppingCart(part)
}
</script>

<style lang="scss" scoped>
// House tokens (--panel, --line, --money, ...) come from the .rls-house panel in PartShoppingMain.
.parts-wrapper {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  min-width: 0;
  width: 100%;
  height: 100%;
  max-height: 100%;
  overflow: hidden;
}

// House search field look on the vanilla BngInput (tokens from the .rls-house panel).
.search-container {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.35em var(--inset, 0.85em) 0.5em;
  > :deep(.bng-input) {
    flex: 1 1 auto;
    min-width: 0;
  }
  :deep(.bng-input) {
    border-radius: var(--radius-panel, 0.5em);
    background: rgba(0, 0, 0, 0.3);
    box-shadow: inset 0 0 0 1px var(--line, rgba(255, 255, 255, 0.1));
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
    color: var(--faint, rgba(255, 255, 255, 0.55));
    --bng-icon-color: currentColor;
  }
  :deep(.bng-input label) {
    color: var(--faint, rgba(255, 255, 255, 0.55));
  }
}

.parts-list {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  box-sizing: border-box;
  padding: 0 0.35em 0.5em var(--inset, 0.85em);
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
  &::-webkit-scrollbar-thumb:active { background: var(--accent, #ff6600); background-clip: padding-box; }
}

.part-item {
  display: flex;
  flex-direction: row;
  flex-wrap: nowrap;
  justify-content: stretch;
  align-items: center;
  gap: var(--space-2, 0.5em);
  width: 100%;
  box-sizing: border-box;
  flex-shrink: 0;
  min-height: 4em;
  padding: 0.5em 0.5em 0.5em 0.6em;
  border-bottom: 1px solid transparent;
  color: #fff;
  > * {
    flex: 1 1 auto;
  }
  &:not(:last-child) {
    border-bottom-color: var(--line, rgba(255, 255, 255, 0.1));
  }
  // Installed part: slightly brighter panel + accent-soft name, no orange bar.
  &.part-installed {
    border-radius: var(--radius-panel, 0.5em);
    border-bottom-color: transparent;
    background: var(--panel-2, rgba(255, 255, 255, 0.1));
    .part-name {
      color: var(--accent-soft, #ffb27a);
    }
  }
  &.disabled {
    opacity: 0.5;
  }
}

// short icon chips in the meta row: Installed (accent) and Inventory (neutral)
.part-info-row > .part-chip {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  gap: 0.3em;
  margin-right: 0.5em;
  padding: 0.28em 0.55em 0.18em 0.4em;
  border-radius: var(--radius-pill, 1em);
  font-size: 0.82em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  align-self: center;
  .bng-icon,
  :deep(.icon-base) {
    font-size: 1.1em;
    transform: translateY(-0.08em);
  }
  &.chip-installed {
    background: rgba(255, 102, 0, 0.16);
    color: var(--accent-soft, #ffb27a);
    --bng-icon-color: currentColor;
  }
  &.chip-owned {
    background: rgba(255, 255, 255, 0.1);
    color: var(--muted, rgba(255, 255, 255, 0.72));
    --bng-icon-color: currentColor;
  }
}

.part-info-col {
  display: flex;
  flex-direction: column;
  justify-content: stretch;
  gap: 0.15em;
  flex: 1 1 0;
  min-width: 0;

  > * {
    max-width: 100%;
    overflow: hidden;
  }
}

.part-info-row {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 0.25em;
  justify-content: stretch;
  align-items: baseline;
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.92em;
  font-weight: 600;
  > * {
    flex: 1 1 auto;
    min-width: 0;
    overflow-wrap: anywhere;
  }
}

// House kit: neutral Install, quiet-danger icon-only Undo.
.part-item .part-button {
  min-width: 6.25em;
  flex: 0 0 auto; /* Prevent it from shrinking or growing */
  &.is-undo :deep(.btn-label) {
    display: none;
  }
}

.part-name {
  display: block;
  font-size: 1.05em;
  font-weight: 700;
  line-height: 1.2;
  white-space: normal;
  overflow-wrap: anywhere;
}

.mileage-text {
  font-size: 0.9em;
  font-weight: 600;
  color: var(--faint, rgba(255, 255, 255, 0.55));
}

.disabled-reason {
  font-size: 0.9em;
  align-self: center;
  white-space: normal;
  overflow-wrap: anywhere;
  word-break: break-word;
  margin-right: 0.5em;
  color: var(--bad, #fca5a5);
}

.center {
  text-align: center;
}
.right {
  flex: 0 0 auto;
  margin-left: auto;
  text-align: right;
  color: var(--money, #fde68a);
  font-variant-numeric: tabular-nums;
  --units-icon-color: var(--money, #fde68a);
  :deep(.info-item) {
    padding-right: 0;
  }
}

.no-results {
  overflow-wrap: anywhere;
  padding: 1.4em 1em;
  text-align: center;
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.92em;
  font-weight: 600;
}
</style>
