<template>
  <Accordion>
    <AccordionItem
      v-for="childSlot in sortedChildren"
      :key="childSlot.path"
      :static="!childSlot.chosenPartName || !childSlot.children || Object.keys(childSlot.children).length === 0"
      :expanded="!!expandedSlots[childSlot.path]"
      :primary-action="() => openSlot(childSlot.path)"
      :expand-on-context="false"
      navigable
      expand-hint-inline
      primary-hint-inline
      @expanded="value => setExpanded(childSlot.path, value)"
      @selected="openSlot(childSlot.path)"
    >
      <template #caption>
        <span class="slot-name">{{ childSlot.slotNiceName }}</span>
      </template>
      <template #controls>
        <HouseButton
          bng-no-nav="true"
          class="buy-button"
          compact
          @click="openSlot(childSlot.path)"
          v-bng-tooltip:top="childSlot.chosenPartNiceName"
        >
          <span class="buy-button-label">{{ childSlot.chosenPartNiceName || "-" }}</span>
        </HouseButton>
      </template>
      <BusinessPartsSlotTree
        v-if="childSlot.children && Object.keys(childSlot.children).length > 0"
        :children="childSlot.children"
        :expanded-slots="expandedSlots"
        @open-slot="openSlot"
        @set-expanded="setExpanded"
      />
    </AccordionItem>
  </Accordion>
</template>

<script setup>
// Stays its own component because it renders itself for each nested slot level.
import { computed } from "vue"
import Accordion from "../PartsAccordion.vue"
import { AccordionItem } from "@/common/components/utility"
import { vBngTooltip } from "@/common/directives"
import { HouseButton } from "../house/index.js"
import BusinessPartsSlotTree from "./BusinessPartsSlotTree.vue"

const props = defineProps({
  children: {
    type: [Array, Object],
    default: () => [],
  },
  expandedSlots: {
    type: Object,
    default: () => ({}),
  },
})

const emit = defineEmits(["open-slot", "set-expanded"])

const sortedChildren = computed(() => Object.values(props.children || {})
  .filter(Boolean)
  .sort((a, b) => (a.slotNiceName || a.slotName || "").localeCompare(b.slotNiceName || b.slotName || "")))

const openSlot = path => emit("open-slot", path)
const setExpanded = (path, expanded) => emit("set-expanded", path, expanded)
</script>

<style lang="scss" scoped>
// Same as the career Part Shop SlotItem; house tokens come from the .rls-house parts panel.
.bng-accitem .buy-button.house-button {
  max-width: 13em !important;
  min-height: unset;
  margin: 0 0 0 0.35em;
  padding: 0.45em 0.7em 0.32em;
  border-radius: var(--radius-tile, 0.4em);
  color: var(--muted, rgba(255, 255, 255, 0.72));
  font-size: 0.9em;
  font-weight: 600;
  line-height: 1.2;
  &:hover:not(:disabled),
  &.focus-visible {
    color: #fff;
  }
  .buy-button-label {
    display: inline-block;
    max-width: 100%;
    white-space: normal;
    overflow-wrap: anywhere;
    text-align: right;
  }
}
.slot-name {
  display: block;
  max-width: 100%;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
  font-weight: 600;
}
:deep() {
  .bng-accitem-caption-content {
    overflow: hidden !important;
    z-index: 0;
  }
  .bng-accitem-caption-controls {
    overflow: visible !important;
    z-index: 1;
  }
  .bng-accitem-caption-expander {
    z-index: 1;
  }
}
// Expanded / selected rows: slightly brighter panel + accent-soft text, no grey-blue fill or orange gradient.
.bng-accitem.bng-accitem.bng-accitem-expanded > :deep(.bng-accitem-caption) {
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
}
.bng-accitem.bng-accitem.bng-accitem-selected > :deep(.bng-accitem-caption) {
  background-image: none !important;
  background-color: var(--panel-2, rgba(255, 255, 255, 0.1));
  .slot-name {
    color: var(--accent-soft, #ffb27a);
  }
}
</style>
