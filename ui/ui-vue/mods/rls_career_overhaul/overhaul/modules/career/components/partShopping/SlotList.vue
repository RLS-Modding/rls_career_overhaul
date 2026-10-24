<template>
  <div ref="rootEl" class="slot-list-root">
    <div class="search-container">
      <BngInput
        v-model="searchValue"
        :leading-icon="icons.search"
        :label="$translate.instant('ui.common.search')"
        floating-label
        @change="searchValueChanged" />
    </div>

    <div
      class="innerList"
      :class="{ 'search-results': searchValue.length > 0 }"
      v-bng-ui-nav-scroll
    >
      <!-- show a flat list when the user is searching for something -->
      <Accordion v-if="searchValue.length > 0" class="slot-flat-view">
        <SlotItem
          v-for="slotInfo in partShoppingStore.filteredSlots"
          :key="slotInfo.path"
          :static="true"
          :path="slotInfo.path"
          :nicePath="slotInfo.nicePath"
          :slotNiceName="slotInfo.slotNiceName"
          :partNiceName="slotInfo.partNiceName ? slotInfo.partNiceName : null" />
      </Accordion>

      <!-- else show the part tree only if children exists -->
      <PartSubTree
        v-else-if="partShoppingStore.partShoppingData?.partTree?.children"
        class="slot-tree-view"
        :children="partShoppingStore.partShoppingData.partTree.children" />
    </div>
  </div>
</template>

<script setup>
import Accordion from "../PartsAccordion.vue"
import { BngInput, icons } from "@/common/components/base"
import PartSubTree from "./PartSubTree.vue"
import SlotItem from "./SlotItem.vue"
import { vBngUiNavScroll } from "@/common/directives"
import { ref, watch, nextTick } from "vue"
import { refocusIfLost } from "../../composables/useScreenEntryFocus"
import { usePartShoppingStore } from "../../stores/partShoppingStore"
import { $translate } from "@/services/translation"

const partShoppingStore = usePartShoppingStore()

defineProps({
  cancel: Function,
})

const searchValue = ref("")

// Controller entry into the slot list: the first slot, not the search box above it (the scope's
// first navigable item). Coming back from a slot, SlotItem marks that slot instead.
const rootEl = ref(null)
let entryMark = null
let pendingEntry = false
const clearEntryMark = () => {
  entryMark?.removeAttribute("bng-scoped-nav-autofocus")
  entryMark = null
}
// (the panel can switch before the slot tree has arrived, so the tree is watched as well)
watch(
  [() => partShoppingStore.activePanel, () => partShoppingStore.partShoppingData?.partTree],
  ([panel], [prevPanel] = []) => {
    if (panel !== prevPanel) pendingEntry = panel === "slots"
    if (panel === prevPanel && entryMark) return
    clearEntryMark()
    if (panel !== "slots") return
    nextTick(() => setTimeout(() => {
      if (partShoppingStore.activePanel !== "slots") return
      const first = rootEl.value?.querySelector(".innerList .bng-accitem-caption[bng-nav-item]")
      if (!first) return
      const entering = pendingEntry
      pendingEntry = false
      if (!partShoppingStore.slotToScrollTo) {
        entryMark = first
        first.setAttribute("bng-scoped-nav-autofocus", "")
      }
      const active = document.activeElement
      // never pull a player out of the search box they chose; only the scope's default landing on it
      // right at entry is corrected
      if (!active || active === document.body || active.closest?.(".mainCategories") || (entering && active.closest?.(".search-container"))) {
        refocusIfLost(() => rootEl.value?.querySelector(".innerList [bng-scoped-nav-autofocus]") || first, { force: true })
      }
    }, 50))
  },
  { immediate: true }
)

const clearSearch = () => {
  if (!searchValue.value) return false
  searchValue.value = ""
  searchValueChanged()
  return true
}
defineExpose({ clearSearch })

const searchValueChanged = () => {
  partShoppingStore.searchValueChanged(searchValue.value.trim())
}
</script>

<style scoped lang="scss">
.slot-list-root {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  overflow: hidden;
}

// House search field look on the vanilla BngInput (tokens from the .rls-house panel).
.search-container {
  flex: 0 0 auto;
  padding: 0.35em var(--inset, 0.85em) 0.5em;
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

.innerList {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 0.15em 0.5em 0.35em;
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
  & [bng-nav-item] {
    cursor: pointer;
  }
}

.slot-tree-view {
  margin: 0 0.25rem;
}
.slot-flat-view {
  margin: 0 0.75rem;
}

// Flat search rows have no tree indentation. Give both columns a bounded
// share of the panel; the stock controls can otherwise shrink below the button.
.search-results {
  min-width: 0;
  :deep(.bng-accitem-caption) {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 45%);
    width: auto;
    margin: 0;
    gap: 0.35em;
  }
  :deep(.bng-accitem-caption-content),
  :deep(.bng-accitem-caption-controls) {
    min-width: 0;
  }
  :deep(.buy-button.house-button) {
    box-sizing: border-box;
    width: 100%;
    min-width: 0;
    max-width: 100% !important;
    margin-left: 0;
  }
  :deep(.buy-button .btn-label) {
    min-width: 0;
  }
  :deep(.slot-name) {
    white-space: normal;
    overflow-wrap: anywhere;
  }
}
</style>
